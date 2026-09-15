import Foundation

/// Flywheel intent log (spec 2026-09-05 §11): the highest-value training
/// signal the system produces — what the user CONFIRMED, and especially
/// what they CORRECTED — persisted on-device for the family review screen
/// and the periodic export → retrain loop.
///
/// Since 2026-09-15 ([INTENTLOG-CAPTURE]) EVERY confirm-tier verdict is
/// recorded, not just the two that happened to be wired up first:
/// `confirmed` / `denied` / `corrected` / `timeout`, each carrying the
/// interpreter's `confidence` when an interpreted command produced it.
/// `Capture` below is the single verdict → record mapping those paths
/// share.
///
/// Storage: a JSONL file in Application Support with
/// `NSFileProtectionComplete` (constitution §Security — same protection
/// class as the Keychain stores, but the Keychain is the wrong place for
/// an append log). This is deliberately separate from `ObservabilityBus`
/// telemetry, which stays PII-free (C9): this log contains slot values
/// (contact names) by design — it is TRAINING DATA, kept on-device under
/// device protection, and leaves only via the family's explicit export.
///
/// Capped at 500 records (oldest trimmed on write) — the flywheel needs
/// recent corrections, not infinite history.
final class IntentLogStore {

    struct Record: Codable, Equatable, Identifiable {
        let id: UUID
        let timestamp: Date
        /// local | cloud | keyword | cache | override
        let path: String
        let action: String
        /// Slot values as heard/resolved (contact names included — this
        /// is the training payload).
        let slots: [String: String]?
        /// confirmed | denied | corrected | timeout
        let outcome: String
        /// Present on corrections: what the user amended the plan TO.
        let correctedTo: [String: String]?
        /// The interpreter's confidence in `action` (0…1) when this
        /// outcome came from an interpreted command; nil for
        /// touch-originated actions and for every record written before
        /// this field existed.
        ///
        /// Schema evolution (2026-09-15, [INTENTLOG-CAPTURE]): confidence
        /// is the one piece of MODEL metadata the flywheel needs — it
        /// separates a confident mistake from a coin-flip the
        /// confirmation happened to catch, which is exactly what the
        /// accept/rephrase bands are tuned against (T-054).
        let confidence: Double?
        let latencyMs: Int?

        init(path: String, action: String, slots: [String: String]? = nil,
             outcome: String, correctedTo: [String: String]? = nil,
             confidence: Double? = nil,
             latencyMs: Int? = nil, timestamp: Date = Date()) {
            self.id = UUID()
            self.timestamp = timestamp
            self.path = path
            self.action = action
            self.slots = slots
            self.outcome = outcome
            self.correctedTo = correctedTo
            self.confidence = confidence
            self.latencyMs = latencyMs
        }

        /// Tolerant decode (2026-09-15, [INTENTLOG-CAPTURE]): a record
        /// written before `confidence` existed decodes with `confidence`
        /// nil — the honest reading of a line that predates the concept
        /// — and a record whose optional fields were never written
        /// (JSONEncoder omits nil) decodes the same way. A line missing a
        /// MANDATORY field is still dropped by `readAll`'s `compactMap`:
        /// an unreadable line is not a verdict. Same legacy-tolerant
        /// pattern as `ApplianceCache.Entry`'s decoder.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            timestamp = try c.decode(Date.self, forKey: .timestamp)
            path = try c.decode(String.self, forKey: .path)
            action = try c.decode(String.self, forKey: .action)
            slots = try? c.decodeIfPresent([String: String].self, forKey: .slots)
            outcome = try c.decode(String.self, forKey: .outcome)
            correctedTo = try? c.decodeIfPresent([String: String].self, forKey: .correctedTo)
            confidence = try? c.decodeIfPresent(Double.self, forKey: .confidence)
            latencyMs = try? c.decodeIfPresent(Int.self, forKey: .latencyMs)
        }
    }

    static let maxRecords = 500

    private let fileURL: URL
    private let ioQueue = DispatchQueue(label: "intent.log", qos: .utility)
    /// Amortized count for O(1) appends: nil until first read; appends
    /// increment; the file is only fully rewritten when it exceeds
    /// maxRecords + 50 (the trim point), not on every append.
    private var estimatedCount: Int?

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ElderlyAssistant", isDirectory: true)
        fileURL = base.appendingPathComponent("intent-log.jsonl")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.complete])
    }

    // MARK: - Write

    func append(_ record: Record) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            if self.estimatedCount == nil {
                self.estimatedCount = Self.readAll(from: self.fileURL).count
            }
            let line = (try? String(data: JSONEncoder().encode(record), encoding: .utf8)) ?? ""
            guard !line.isEmpty else { return }
            if let handle = try? FileHandle(forWritingTo: self.fileURL) {
                handle.seekToEndOfFile()
                let needsNewline = (try? String(contentsOf: self.fileURL, encoding: .utf8)
                    .hasSuffix("\n")) == false
                handle.write((needsNewline ? "\n" : "").appending(line + "\n").data(using: .utf8)!)
                try? handle.close()
            } else {
                try? (line + "\n").write(to: self.fileURL, atomically: true, encoding: .utf8)
            }
            self.estimatedCount! += 1
            // Trim only when well past the cap — amortizes the rewrite.
            if self.estimatedCount! > Self.maxRecords + 50 {
                let records = Array(Self.readAll(from: self.fileURL).suffix(Self.maxRecords))
                Self.writeAll(records, to: self.fileURL)
                self.estimatedCount = records.count
            }
        }
    }

    // MARK: - Read

    /// Newest-first, for the family review screen. Synchronous — the file
    /// is small by design (≤500 rows).
    func recent(limit: Int = 100) -> [Record] {
        Array(Self.readAll(from: fileURL).suffix(limit).reversed())
    }

    var count: Int { Self.readAll(from: fileURL).count }

    /// A shareable copy in tmp — ShareLink hands it to the family (they
    /// AirDrop/email it to themselves; it becomes the next training batch).
    func exportURL() -> URL? {
        let records = Self.readAll(from: fileURL)
        guard !records.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sahayak-intent-log-\(formatter.string(from: Date())).jsonl")
        let text = records.map { rec -> String in
            (try? String(data: JSONEncoder().encode(rec), encoding: .utf8)) ?? ""
        }.filter { !$0.isEmpty }.joined(separator: "\n")
        do {
            try text.write(to: tmp, atomically: true, encoding: .utf8)
            return tmp
        } catch {
            return nil
        }
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - File helpers

    private static func readAll(from url: URL) -> [Record] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(Record.self, from: data)
        }
    }

    private static func writeAll(_ records: [Record], to url: URL) {
        let text = records.map { rec -> String in
            (try? String(data: JSONEncoder().encode(rec), encoding: .utf8)) ?? ""
        }.filter { !$0.isEmpty }.joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete],
                                               ofItemAtPath: url.path)
    }
}

// MARK: - [INTENTLOG-CAPTURE] Verdict → record mapping

extension IntentLogStore {

    /// The four ways a confirm-tier confirmation can end (spec 2026-09-05
    /// §11). The raw values ARE the persisted `outcome` vocabulary —
    /// never rename a case: it is a storage format.
    enum Verdict: String {
        /// The user said yes and the action ran.
        case confirmed
        /// The user said no (or declined via the confirmation chips).
        case denied
        /// The user amended the plan instead of accepting it — the
        /// flywheel's gold sample (`correctedTo` carries the amendment).
        case corrected
        /// The 45 s confirmation window expired with no answer.
        case timeout
    }

    /// One confirm-tier confirmation's flywheel identity: what the
    /// interpreter asked about, the slots it resolved, its confidence,
    /// and when the question was asked. Built when a confirmation is
    /// pended and turned into a `Record` when the verdict lands — so
    /// confirmed / denied / timeout / corrected all travel ONE mapping
    /// instead of four hand-rolled appends.
    ///
    /// The record is only ever written from a VERDICT. What the flow does
    /// with the verdict (dial, write the event, clear the pending action)
    /// stays the flow's business — this type is the capture seam only.
    struct Capture: Equatable {
        let action: String
        let slots: [String: String]?
        let confidence: Double?
        /// When the confirmation question was asked. `latencyMs` is the
        /// question→verdict time: how long the elder needed to decide —
        /// a care signal in its own right, and the number the 45 s
        /// window is calibrated against. Nil = unknown start, and the
        /// record then carries no latency at all (never a fabricated 0).
        let requestedAt: Date?

        init(action: String, slots: [String: String]? = nil,
             confidence: Double? = nil, requestedAt: Date? = nil) {
            self.action = action
            self.slots = slots
            self.confidence = confidence
            self.requestedAt = requestedAt
        }

        /// The verdict → record mapping. `path` names the interpreter
        /// layer that produced the command — "model" for the interpreted
        /// path (the only layer with a confirmation flow), "override"
        /// for the call-correction protocol, which keeps the value the
        /// pre-2026-09-15 code already wrote for it.
        func record(_ verdict: Verdict,
                    path: String = "model",
                    correctedTo: [String: String]? = nil,
                    at now: Date = Date()) -> Record {
            Record(path: path, action: action, slots: slots,
                   outcome: verdict.rawValue, correctedTo: correctedTo,
                   confidence: confidence, latencyMs: latencyMs(at: now),
                   timestamp: now)
        }

        /// Whole milliseconds from the question to the verdict, floored
        /// at 0 (a clock that stepped backwards must not write a negative
        /// latency). Nil when the start is unknown.
        private func latencyMs(at now: Date) -> Int? {
            guard let requestedAt else { return nil }
            return max(0, Int((now.timeIntervalSince(requestedAt) * 1000).rounded()))
        }
    }
}
