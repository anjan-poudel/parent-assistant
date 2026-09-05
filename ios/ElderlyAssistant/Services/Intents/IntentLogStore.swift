import Foundation

/// Flywheel intent log (spec 2026-09-05 §11): the highest-value training
/// signal the system produces — what the user CONFIRMED, and especially
/// what they CORRECTED — persisted on-device for the family review screen
/// and the periodic export → retrain loop.
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
        let latencyMs: Int?

        init(path: String, action: String, slots: [String: String]? = nil,
             outcome: String, correctedTo: [String: String]? = nil,
             latencyMs: Int? = nil, timestamp: Date = Date()) {
            self.id = UUID()
            self.timestamp = timestamp
            self.path = path
            self.action = action
            self.slots = slots
            self.outcome = outcome
            self.correctedTo = correctedTo
            self.latencyMs = latencyMs
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
