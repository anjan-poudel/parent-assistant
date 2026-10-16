import Foundation

/// One curated option inside a dialogue-option group (design-l2 §11,
/// C-MTC-04). `query` is the canonical search string the answer merge
/// substitutes; `aliases` are match vocabulary, never spoken.
struct DialogueOption: Equatable {
    let id: String
    let labelKey: String
    let query: String
    let aliases: [String]
}

/// A curated group of pickable options for one probe question
/// (design-l2 §11). `matchKeys` is group-selection vocabulary (L2-D12),
/// never spoken.
struct DialogueOptionGroup: Equatable {
    let id: String
    let questionKey: String
    let matchKeys: [String]
    let options: [DialogueOption]
}

/// The curated on-device dialogue option catalog: a versioned bundled
/// JSON resource plus whole-value / whole-token lookups (design-l2 §11,
/// C-MTC-04). Immutable after load — safe from any thread.
///
/// Matching follows the repo's script-split idiom shared with
/// `KeywordIntentRule`'s vocabulary keys: Devanagari keys match by
/// grapheme-aware containment (postpositions fuse onto the stem —
/// "भजनहरू" ⊃ "भजन"), everything else by whole-token equality. Swift
/// compares whole extended grapheme clusters, so the near-pair
/// "गीता" can never match "गीत" — the trailing matra is a different
/// cluster, never a naive prefix (the 2026-09-07 grapheme lesson).
///
/// Failure behaviour (design-l2 §11): malformed JSON, an unsupported
/// version and structural schema violations all throw the closed
/// `DialogueError.catalogUnavailable` — no partially parsed groups are
/// ever returned. The caller (the router's one cached load) stores nil
/// and degrades to the free-text-only probe. Entirely local: no
/// network client, no URL session, no telemetry (NFR-MTC-003).
struct DialogueOptionCatalog: Equatable {
    /// The bundled resource name (app-target entry in `ios/project.yml`).
    static let bundledResourceName = "DialogueOptionCatalog"
    /// The only schema version this loader accepts.
    static let supportedVersion = 1

    let version: Int
    /// Ordered by the JSON file's array order (L2-D12) — group
    /// selection is first-match in this order.
    let groups: [DialogueOptionGroup]

    /// Decodes and validates a version-1 catalog payload. Any parse or
    /// schema failure throws `.catalogUnavailable` (fail closed, all or
    /// nothing).
    init(data: Data) throws {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw DialogueError.catalogUnavailable
        }
        guard payload.version == Self.supportedVersion,
              !payload.groups.isEmpty,
              payload.groups.allSatisfy(\.isStructurallyValid) else {
            throw DialogueError.catalogUnavailable
        }
        self.version = payload.version
        self.groups = payload.groups.map(\.value)
    }

    /// Loads the bundled catalog resource. Throws `.catalogUnavailable`
    /// when the resource is missing or malformed — the caller decides
    /// how to degrade (free-text-only probe + default).
    static func load(bundle: Bundle = .main,
                     resource: String = DialogueOptionCatalog.bundledResourceName) throws -> DialogueOptionCatalog {
        guard let url = bundle.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            throw DialogueError.catalogUnavailable
        }
        return try DialogueOptionCatalog(data: data)
    }

    /// The group with this id, nil when absent.
    func group(_ id: String) -> DialogueOptionGroup? {
        groups.first { $0.id == id }
    }

    /// First group (file order) whose matchKeys hit the canonicalized
    /// query; nil when nothing claims it (L2-D12).
    func groupForMusicQuery(_ query: String) -> DialogueOptionGroup? {
        let text = Self.canonical(query)
        guard !text.isEmpty else { return nil }
        return groups.first { group in
            group.matchKeys.contains { Self.matches(key: $0, in: text) }
        }
    }

    /// Whole-value alias match (the caller passes the value and the
    /// marker-dropped variant separately); nil when nothing matches.
    func option(matchingWholeValue value: String, in group: DialogueOptionGroup) -> DialogueOption? {
        let text = Self.canonical(value)
        guard !text.isEmpty else { return nil }
        return group.options.first { option in
            option.aliases.contains { Self.matches(key: $0, in: text) }
        }
    }

    // MARK: - Matching (the script-split idiom)

    /// Lowercase + interior-whitespace collapse — the same
    /// canonicalization the router applies before its phrase stages,
    /// so a direct call with a raw transcript behaves like one with
    /// the router's pre-canonicalized text.
    private static func canonical(_ raw: String) -> String {
        raw.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Devanagari block (U+0900–U+097F) — answers "does this key fuse
    /// postpositions onto its stem?", the only question the match-mode
    /// split asks.
    private static func containsDevanagari(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
    }

    /// Whole-token split — same semantics as
    /// `CommandRouter.containsToken` (whitespace/punctuation split,
    /// exact equality).
    private static func tokens(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .filter { !$0.isEmpty }
    }

    /// One match key against one canonicalized text. Devanagari (and
    /// multi-word) keys: grapheme-aware containment. Single Latin
    /// words: whole-token equality — containment would turn "bhajan"
    /// into "bhajans" and "shiva" into "shivaji".
    private static func matches(key rawKey: String, in text: String) -> Bool {
        let key = canonical(rawKey)
        guard !key.isEmpty else { return false }
        if key.contains(" ") || containsDevanagari(key) {
            return text.contains(key)
        }
        return tokens(in: text).contains(key)
    }

    // MARK: - Version-1 payload (private decode shape)

    private struct Payload: Decodable {
        let version: Int
        let groups: [GroupPayload]
    }

    private struct GroupPayload: Decodable {
        let id: String
        let questionKey: String
        let matchKeys: [String]
        let options: [OptionPayload]

        /// v1 shape: every identity/key string non-empty and every
        /// list non-empty — an option without a query or an unpickable
        /// group is malformed, not partial data.
        var isStructurallyValid: Bool {
            isNonEmpty(id)
                && isNonEmpty(questionKey)
                && !matchKeys.isEmpty && matchKeys.allSatisfy(isNonEmpty)
                && !options.isEmpty && options.allSatisfy(\.isStructurallyValid)
        }

        var value: DialogueOptionGroup {
            DialogueOptionGroup(id: id,
                                questionKey: questionKey,
                                matchKeys: matchKeys,
                                options: options.map(\.value))
        }
    }

    private struct OptionPayload: Decodable {
        let id: String
        let labelKey: String
        let query: String
        let aliases: [String]

        var isStructurallyValid: Bool {
            isNonEmpty(id)
                && isNonEmpty(labelKey)
                && isNonEmpty(query)
                && !aliases.isEmpty && aliases.allSatisfy(isNonEmpty)
        }

        var value: DialogueOption {
            DialogueOption(id: id, labelKey: labelKey, query: query, aliases: aliases)
        }
    }

    private static func isNonEmpty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
