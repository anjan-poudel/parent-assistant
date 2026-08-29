import Foundation

// MARK: - Double Dose Detector (FR-D03)

struct DoubleDoseCheckResult {
    let isDuplicate: Bool
    let previousDoseAt: Date?
    let windowEndsAt: Date?
}

final class DoubleDoseDetector {
    /// Check whether the given medication has already been acknowledged within its
    /// double-dose prevention window.
    ///
    /// - Parameters:
    ///   - medicationEntryId: The medication being checked
    ///   - windowHours: Configurable window (default 4 for once-daily, 2 for twice-daily)
    ///   - adherenceLog: The on-device adherence log entries for this medication today
    ///   - now: Current time
    /// - Returns: DoubleDoseCheckResult indicating whether a duplicate was found
    func check(
        medicationEntryId: UUID,
        windowHours: Int,
        adherenceLog: [MedicationAdherenceLog],
        now: Date
    ) -> DoubleDoseCheckResult {
        let windowStart = now.addingTimeInterval(-TimeInterval(windowHours * 3600))

        let previousDose = adherenceLog
            .filter { $0.medicationEntryId == medicationEntryId }
            .filter { $0.status == .acknowledged }
            .filter { log in
                if let ackAt = log.acknowledgedAt {
                    return ackAt >= windowStart && ackAt <= now
                }
                return false
            }
            .sorted { a, b in
                (a.acknowledgedAt ?? .distantPast) > (b.acknowledgedAt ?? .distantPast)
            }
            .first

        guard let previous = previousDose, let previousAt = previous.acknowledgedAt else {
            return DoubleDoseCheckResult(
                isDuplicate: false,
                previousDoseAt: nil,
                windowEndsAt: nil
            )
        }

        let windowEndsAt = previousAt.addingTimeInterval(TimeInterval(windowHours * 3600))

        return DoubleDoseCheckResult(
            isDuplicate: true,
            previousDoseAt: previousAt,
            windowEndsAt: windowEndsAt
        )
    }
}
