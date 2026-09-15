import Foundation

// MARK: - TG-12 canonicalization layer (Phase 1: the half that can act today)
//
// Design: docs/superpowers/specs/2026-09-15-crux-resolution-pipeline-design.md
//   §4.2 the contract, §4.3 the table schema, §4.4 the orthographic rules,
//   §4.5 provenance, §4.6 composition, §4.7 losslessness for safety.
// Dialect inventory: specs/T-062-notes.md + specs/T-062-dialect-banks.yaml.
//
// What this file ships, and what it deliberately does NOT.
//
// SHIPS:
//   - `DialectCanonicalizer`: a pure, deterministic, synchronous, non-throwing
//     pre-intent normalizer that rewrites attested variant surface forms onto
//     canonical forms and returns the canonical transcript plus per-application
//     provenance (rule id, table id, kind, original range, canonical range).
//   - `VariantTable` / `VariantTableEntry` / `VariantTableSet`: the variant
//     tables as DATA, in the shape §4.3 specifies. A T-062 bank, or the
//     measured STT-error lexicon from
//     `tools/train-intent/src/extract_stt_errors.py` (its `noisy → corrected`
//     rows carry exactly the `variant`/`canonical` + `evidence.occurrences` +
//     `evidence.rowIDs` + run-revision this schema asks for), attaches by
//     dropping a JSON file into `Resources/VariantTables/` — no code change.
//   - `CanonicalSafetyFreeze`: §4.7's frozen material and the matcher the
//     losslessness invariant is stated over.
//   - `IntentTranscriptPair` + `IntentInputCanonicalization`: the composition
//     seam. The intent model's input is the canonical transcript; the keyword
//     safety net's input is ALWAYS the original (D-1).
//
// INERT UNTIL A LATER WIRING TASK FLIPS IT ON. The runtime policy is
// `IntentEncoderFeature.isEnabled && CanonicalizerPreferences.canonicalizerEnabled`,
// and the persisted toggle reads an absent key as FALSE (house pattern:
// `IntentEncoderPreferences`, `DialectBiasSettings`). With either gate off the
// seam returns the sanitised transcript byte-identical and records no
// applications — no routing, band, cache or safety-net behaviour changes, and
// no band constant is read or written.
//
// This half is the one that can act at all today. The design's §3 ground-truth
// finding: the persisted dialect label has no production writer (its only
// writer, `WhisperKitSpeechRecognizer.applyDialectLabel`, has no callers), the
// shipped centroid table is SEED-CENTROIDS and could not clear its own gate,
// and T-062 files every region-marked slice as CONDITIONAL pending
// native-speaker answers N1–N14. So the orthographic + pan-regional tables are
// what may fire; every region-marked table is loaded as data but not consulted
// until `Policy.includeConditionalTables` is set deliberately.
//
// Out of scope, recorded because each is a plausible over-reach:
//   - No learned component, no fuzzy match, no edit distance, no
//     transliteration, no translation, no spell-checker (design §5, D-2).
//   - No span remap wired into the encoder's decoder. §4.5's map is provided
//     (`IntentTranscriptPair.originalRange(forCanonicalRange:)`) for the task
//     that wires it; this task does not change the decode path's spans.
//   - No observability event is emitted here. `CanonicalizationResult
//     .observabilityMetadata` carries the rule ids, table ids, kinds and
//     counts a caller may emit — never an original or canonical surface form
//     (§6.6, NFR-016, R-9).

// MARK: - Rule kind

/// The closed four-value rule kind, and the stage each one runs in (§4.2).
///
/// Decoding also accepts T-062's dialect-axis vocabulary (`orthographic |
/// lexical | morphophonemic`, `specs/T-062-dialect-banks.yaml:11`), so a T-062
/// bank is loadable as data with no transformation. `lexical` and
/// `morphophonemic` both land on `.lexicalVariant`: T-062 draws that line for
/// *model impact* (a genuinely different word form vs a spelling of a word the
/// model knows), which is not a difference in when the rewrite must run.
enum CanonicalizationKind: String, Sendable, CaseIterable {
    /// Halanta / anusvara / diacritic surface form — stage 1.
    case orthographic
    /// STT word-boundary repair — stage 2. §4.4 files O-6 as the highest-risk
    /// rule in the set; the freeze in `CanonicalSafetyFreeze` is what scopes
    /// it, and it may never join or split across a frozen token.
    case misSegmentation
    /// A different word form (dialect or pan-regional) — stage 3.
    case lexicalVariant
    /// Elder telegraphic register — stage 4, last, because it may depend on
    /// lexical context.
    case clippedForm

    /// Maps a raw `kind` string from either vocabulary onto the runtime stage.
    /// Returns nil for anything else — the table then reports `.unknownKind`
    /// rather than silently dropping or guessing.
    static func mapping(_ raw: String) -> CanonicalizationKind? {
        switch raw {
        case "orthographic": return .orthographic
        case "misSegmentation": return .misSegmentation
        case "lexicalVariant": return .lexicalVariant
        case "clippedForm": return .clippedForm
        // T-062 dialect-axis vocabulary.
        case "lexical", "morphophonemic": return .lexicalVariant
        default: return nil
        }
    }

    /// Stage order (§4.2). Lower runs first.
    var stageOrder: Int {
        switch self {
        case .orthographic: return 1
        case .misSegmentation: return 2
        case .lexicalVariant: return 3
        case .clippedForm: return 4
        }
    }
}

// MARK: - Applied rewrite

/// A single applied rewrite. Every application is recorded; there is no
/// silent rewrite path (§4.2, D-5).
struct CanonicalVariantApplication: Equatable, Sendable {
    /// Which stage the rule ran in — the design names this nested `Kind`.
    typealias Kind = CanonicalizationKind

    /// The rule that fired — table id + entry id, so a log line names a
    /// reviewable row rather than "normalizer".
    let ruleID: String
    /// Which table contributed it (per-region or dialect-agnostic).
    let tableID: String
    /// The dialect the table was selected for; nil for a pan-regional rule.
    let dialect: DialectLabel?
    let kind: Kind
    /// Half-open UNICODE-SCALAR offset ranges — the contract's
    /// `slots.offsets.unit: unicode_scalar`, base 0, end exclusive
    /// (`tools/train-intent/annotation_rules.yaml:96-101`), which is also
    /// literally what the shipped decoder slices with
    /// (`IntentEncoderInterpreter.wordScalarOffsets` / `.scalarSlice`).
    ///
    /// NOT UTF-16 and NOT `Character` counts. The design's §4.2 cites
    /// `annotation_rules.yaml:96-104` for a UTF-16 unit; the cited section
    /// declares the opposite, and its `swift_note` names UTF-16 offsets as "a
    /// known regression class for this project". The contract wins.
    let originalRange: Range<Int>
    let canonicalRange: Range<Int>
    /// The exact surface forms, for the fixture diff. NEVER emitted to
    /// observability (§6.6, R-9).
    let original: String
    let canonical: String
}

/// The canonicalized transcript plus what produced it (§4.2).
struct CanonicalizationResult: Sendable {
    /// The model-input transcript. Byte-identical to the input when no rule
    /// fired, and byte-identical to the input whenever `policy.enabled` is
    /// false or the input is empty.
    let canonical: String
    /// Empty iff `canonical == original`. Order is by `canonicalRange`.
    let applications: [CanonicalVariantApplication]
    /// Which table set produced this, and its revision — the anchor for the
    /// design's §14 evidence pack and the §7 loop.
    let tableRevision: String
    /// True when a structurally corrupt table forced that table's passthrough
    /// (§4.3, D-4), or when a requested dialect table was not available.
    let degraded: Bool
    /// Why the tables fell out the way they did — rejected-table counts and
    /// dialect selection reasons, as fixed-vocabulary strings. PII-free by
    /// construction: table ids and issue counts only, never a surface form
    /// (§6.6, NFR-016).
    let notes: [String]

    /// True when nothing was rewritten.
    var isIdentity: Bool { applications.isEmpty }

    /// Metadata a caller may emit for observability. Rule ids, table ids,
    /// kinds and counts ONLY — the strings being rewritten are, by
    /// construction, the user's own words (§6.6, NFR-016, R-9).
    var observabilityMetadata: [String: String] {
        CanonicalizationObservability.metadata(tableRevision: tableRevision,
                                               applications: applications,
                                               degraded: degraded,
                                               notes: notes)
    }
}

/// The one place the observability payload is assembled, shared by the
/// canonicalization result and the composed pair so the two cannot drift into
/// different disclosure rules (§6.6, NFR-016, R-9).
///
/// What goes in: rule ids, table ids, rule kinds, counts, the table revision,
/// and the fixed-vocabulary notes. What never goes in: a variant form, a
/// canonical form, or any part of the transcript.
enum CanonicalizationObservability {
    static func metadata(tableRevision: String,
                         applications: [CanonicalVariantApplication],
                         degraded: Bool,
                         notes: [String]) -> [String: String] {
        var metadata: [String: String] = [
            "table_revision": tableRevision,
            "application_count": String(applications.count),
            "degraded": degraded ? "true" : "false"
        ]
        if !applications.isEmpty {
            metadata["rule_ids"] = applications.map(\.ruleID).joined(separator: ",")
            metadata["table_ids"] = Set(applications.map(\.tableID)).sorted().joined(separator: ",")
            metadata["kinds"] = Set(applications.map(\.kind.rawValue)).sorted().joined(separator: ",")
        }
        if !notes.isEmpty {
            metadata["notes"] = notes.joined(separator: ",")
        }
        return metadata
    }
}

// MARK: - Table entry

/// One authored rule (§4.3). `id`, `kind`, `variant`, `canonical` and
/// `evidence` are the fields the design's schema table lists; `status`,
/// `modelImpact`, `resolves` and `note` are T-062's per-entry attribution
/// fields, carried so a T-062 bank is loadable as data unchanged.
struct VariantTableEntry: Equatable, Sendable {

    /// Where the rule came from (§4.3.1). A rule with none of these is not
    /// authored — D-8: the absence is reported, never filled with a guess.
    enum Source: String, Sendable, CaseIterable, Decodable {
        case corpus
        case fixture
        case authored
    }

    /// T-062's evidence state (`specs/T-062-dialect-banks.yaml:14-16`).
    /// `unconfirmed` means "needs the native-speaker answer named in
    /// `resolves`" — an unconfirmed entry does NOT fire, whatever the policy
    /// says. It is an authoring state, not a policy arm: pending the answer
    /// the rule is not authored yet.
    /// `Decodable` via the raw value: an unknown status is a decode failure and
    /// therefore a failed file (D-4), never a silently-inert entry — the two
    /// states the file can be in are "reviewed" and "not reviewed yet", and a
    /// third spelling of either is a broken bank, not a new state.
    enum Status: String, Sendable, CaseIterable, Decodable {
        case confirmed
        case unconfirmed
    }

    /// `source == .corpus` requires the revision the frequency was measured on
    /// and an occurrence count ≥ 1; any other source requires ≥ 2 cited
    /// examples (§4.3.1).
    struct Evidence: Equatable, Sendable {
        let source: Source
        let corpusRevision: String?
        let rowIDs: [String]
        let occurrences: Int
        let fixtureExamples: [String]

        static let authoredEmpty = Evidence(source: .authored,
                                            corpusRevision: nil,
                                            rowIDs: [],
                                            occurrences: 0,
                                            fixtureExamples: [])
    }

    let id: String
    /// The raw `kind` from the file, kept verbatim so an unrecognised value is
    /// a reported `.unknownKind` issue rather than a decode failure.
    let kindRaw: String
    let variant: String
    let canonical: String
    let status: Status
    /// T-062 `model_impact`: `known_word | new_word | unknown`. Metadata only —
    /// nothing in this file reads it, and it is never a reason to fire.
    let modelImpact: String?
    /// T-062's review-pack question ids (`N1`–`N14`). Metadata only, so a
    /// reader can see which unanswered question an entry waits on.
    let resolves: [String]
    let note: String?
    let evidence: Evidence

    /// The runtime stage, or nil for an unrecognised `kind`.
    var kind: CanonicalizationKind? { CanonicalizationKind.mapping(kindRaw) }

    /// True when this entry may fire at all.
    var isRunnable: Bool { status == .confirmed && kind != nil }

    /// True when the entry carries a reviewable justification for existing.
    ///
    /// §4.3.1: `corpus` requires the revision the frequency was measured on
    /// and at least one occurrence; any other source requires at least two
    /// cited examples — the anti-fabrication floor, since a rule with no
    /// measurable provenance must at least point at two concrete forms someone
    /// can check.
    var hasEvidence: Bool {
        switch evidence.source {
        case .corpus:
            return evidence.occurrences >= 1
                && (evidence.corpusRevision?.isEmpty == false)
        case .fixture, .authored:
            return evidence.fixtureExamples.count >= 2
        }
    }

    /// True when NO provenance was attempted at all — the entry is an
    /// assertion with nothing behind it. Distinguished from
    /// `evidenceContradictsSource` so the two issues mean different things: a
    /// blank entry and a self-refuting one are different authoring failures,
    /// and collapsing them would make the issue list a single "bad" bucket.
    var hasNoEvidence: Bool {
        evidence.corpusRevision == nil
            && evidence.rowIDs.isEmpty
            && evidence.occurrences == 0
            && evidence.fixtureExamples.isEmpty
    }
}

extension VariantTableEntry: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, variant, canonical, status, modelImpact, resolves, note, evidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kindRaw = try container.decode(String.self, forKey: .kind)
        variant = try container.decode(String.self, forKey: .variant)
        canonical = try container.decode(String.self, forKey: .canonical)
        // A missing `status` is `confirmed`: the pan-regional spelling-drift
        // rows T-062 files with a `basis` carry no status key, and the
        // dialect rows all state one explicitly. A malformed value fails the
        // decode, which fails the whole file closed (D-4).
        status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .confirmed
        modelImpact = try container.decodeIfPresent(String.self, forKey: .modelImpact)
        resolves = try container.decodeIfPresent([String].self, forKey: .resolves) ?? []
        note = try container.decodeIfPresent(String.self, forKey: .note)
        evidence = try container.decodeIfPresent(Evidence.self, forKey: .evidence) ?? .authoredEmpty
    }
}

extension VariantTableEntry.Evidence: Decodable {
    private enum CodingKeys: String, CodingKey {
        case source, corpusRevision, rowIDs, occurrences, fixtureExamples
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Qualified: an extension on the NESTED type does not inherit the outer
        // type's nested-type scope, so a bare `Source` does not resolve here.
        source = try container.decode(VariantTableEntry.Source.self, forKey: .source)
        corpusRevision = try container.decodeIfPresent(String.self, forKey: .corpusRevision)
        rowIDs = try container.decodeIfPresent([String].self, forKey: .rowIDs) ?? []
        occurrences = try container.decodeIfPresent(Int.self, forKey: .occurrences) ?? 0
        fixtureExamples = try container.decodeIfPresent([String].self, forKey: .fixtureExamples) ?? []
    }
}

// MARK: - Table

/// One variant table — one JSON file (§4.3, §9.2). Content, not code: the
/// linguist/calibration pipeline replaces the JSON without an app change (the
/// shape `DialectLexicon` and `DialectCentroidTable` already ship, D-3).
struct VariantTable: Equatable, Sendable {
    struct Generation: Equatable, Sendable {
        /// "SEED-CANONICAL" while authored seed content; the pipeline's own
        /// status once it has replaced the file.
        let status: String
        /// Human-readable provenance of the authoring.
        let path: String
        let date: String?
    }

    let formatVersion: Int
    /// Stable id, used in `applications[].tableID` and every log line.
    let tableID: String
    /// nil for the dialect-agnostic tables; the raw label otherwise. Kept raw
    /// so an unrecognised value is a reported issue, not a decode failure.
    let dialectRaw: String?
    let generation: Generation
    let entries: [VariantTableEntry]

    /// The parsed label, or nil for a dialect-agnostic table / an unknown id.
    var dialect: DialectLabel? {
        guard let dialectRaw else { return nil }
        return DialectLabel(rawValue: dialectRaw)
    }

    /// §4.3's `issues()`, in the design's order and with the design's names.
    /// Per-table and fail-closed (D-4, §9.2): a table with any issue
    /// canonicalizes nothing — partial application of a corrupt table is the
    /// one outcome worse than no canonicalization, because it produces a
    /// transcript that is neither the original nor a known canonical form.
    enum Issue: Equatable, Sendable {
        case unsupportedFormatVersion(Int)
        case emptyEntries
        case duplicateEntryID(String)
        case unknownKind(String)
        case emptyVariantOrCanonical(entry: String)
        case evidenceMissing(entry: String)
        case evidenceContradictsSource(entry: String)
        case variantEqualsCanonical(entry: String)
        case negationMarkerTouched(entry: String)
        /// Not in the design's list, and recorded anyway: a table whose
        /// `dialect` names no shipped label cannot be selected at runtime, and
        /// silently ignoring the field would let a mislabelled file act as the
        /// pan-regional one.
        case unknownDialect(String)
    }

    func issues() -> [Issue] {
        var found: [Issue] = []
        if formatVersion != 1 { found.append(.unsupportedFormatVersion(formatVersion)) }
        if entries.isEmpty { found.append(.emptyEntries) }
        if let dialectRaw, dialect == nil { found.append(.unknownDialect(dialectRaw)) }

        var seen = Set<String>()
        for entry in entries {
            if !seen.insert(entry.id).inserted {
                found.append(.duplicateEntryID(entry.id))
            }
            if entry.kind == nil {
                found.append(.unknownKind(entry.kindRaw))
            }
            if entry.variant.isEmpty || entry.canonical.isEmpty {
                found.append(.emptyVariantOrCanonical(entry: entry.id))
            }
            if entry.hasNoEvidence {
                found.append(.evidenceMissing(entry: entry.id))
            } else if !entry.hasEvidence {
                found.append(.evidenceContradictsSource(entry: entry.id))
            }
            if entry.variant == entry.canonical {
                found.append(.variantEqualsCanonical(entry: entry.id))
            }
            if CanonicalSafetyFreeze.touches(variant: entry.variant,
                                              canonical: entry.canonical) {
                found.append(.negationMarkerTouched(entry: entry.id))
            }
        }
        return found
    }

    /// The entries this table may apply under `policy`, in table order.
    /// Stage ordering is the caller's business (`DialectCanonicalizer`).
    func applicableEntries(policy: DialectCanonicalizer.Policy) -> [VariantTableEntry] {
        entries.filter { entry in
            guard entry.isRunnable else { return false }
            if policy.orthographicOnly && entry.kind != .orthographic { return false }
            return true
        }
    }

    /// How many loaded entries the policy leaves inert, as a count only.
    /// Reported so an unconfirmed bank is visible in provenance rather than
    /// silently absent (§4.3.1's coverage-gap discipline).
    func inertEntryCount(policy: DialectCanonicalizer.Policy) -> Int {
        entries.count - applicableEntries(policy: policy).count
    }
}

extension VariantTable: Decodable {
    private enum CodingKeys: String, CodingKey {
        case formatVersion, tableID, dialect, generation, entries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 0
        generation = try container.decode(Generation.self, forKey: .generation)
        entries = try container.decodeIfPresent([VariantTableEntry].self, forKey: .entries) ?? []
        dialectRaw = try container.decodeIfPresent(String.self, forKey: .dialect)
        // The design's JSON shows no `tableID`; one is derived from `dialect`
        // when the file omits it, so a hand-written T-062 bank still lands.
        tableID = try container.decodeIfPresent(String.self, forKey: .tableID)
            ?? dialectRaw.map { "canonical-\($0)" }
            ?? "canonical-panregional"
    }
}

extension VariantTable.Generation: Decodable {
    private enum CodingKeys: String, CodingKey { case status, path, date }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "UNKNOWN"
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        date = try container.decodeIfPresent(String.self, forKey: .date)
    }
}

// MARK: - Table set

/// The loaded table set plus the selection rules of §4.3.
struct VariantTableSet: Equatable, Sendable {

    /// The dialect-agnostic orthographic table (`canonical-orthographic.json`).
    let orthographic: VariantTable?
    /// The dialect-agnostic pan-regional drift table
    /// (`canonical-panregional.json`).
    let panRegional: VariantTable?
    /// The dialect-agnostic STT-reduction table
    /// (`canonical-stt-reductions.json`) — the landing site for the measured
    /// error lexicon. `tools/train-intent/src/extract_stt_errors.py` (committed)
    /// emits `noisy → corrected` rows with `evidence.runRevision`,
    /// `evidence.occurrences`, `evidence.registers` and `evidence.rowIDs`;
    /// its output is pending a server run, so this file ships with only the one
    /// reduction T-062 itself attests and the rest attaches as data.
    ///
    /// A missing file is normal, not degraded: this table is an attachment by
    /// construction (D-3).
    let sttReductions: VariantTable?
    /// Region-marked tables, keyed by the label they declare. Every one of
    /// them is CONDITIONAL per T-062 until the native-speaker answers land.
    let dialectTables: [DialectLabel: VariantTable]

    /// Non-fatal load notes, as fixed-vocabulary strings (a resource name and
    /// a reason — never file content). Informational: see `degraded`.
    let loadIssues: [String]

    static let empty = VariantTableSet(orthographic: nil,
                                       panRegional: nil,
                                       sttReductions: nil,
                                       dialectTables: [:],
                                       loadIssues: [])

    /// `loadIssues` prefixes. Absence is informational; an undecodable file, or
    /// one whose declared dialect disagrees with its filename, is a real
    /// degradation — a file that shipped and cannot be trusted is a pipeline
    /// failure rather than an unattached attachment.
    static let resourceAbsentPrefix = "resource_absent:"
    static let resourceUndecodablePrefix = "resource_undecodable:"
    static let resourceDialectMismatchPrefix = "resource_dialect_mismatch:"

    /// True when something that SHOULD have been usable was not: a shipped file
    /// that failed to decode, or a region-named file that declares a different
    /// (or no) dialect. A resource that is simply not shipped is not counted —
    /// the STT bank and the region tables are optional attachments (D-3), and
    /// flagging their absence would report every install as degraded.
    var hasLoadDegradation: Bool {
        loadIssues.contains {
            $0.hasPrefix(Self.resourceUndecodablePrefix)
                || $0.hasPrefix(Self.resourceDialectMismatchPrefix)
        }
    }

    /// The tables a canonicalization run consults, with the per-table
    /// fail-closed rule already applied.
    struct Selection: Sendable {
        let tables: [VariantTable]
        /// True when a table was rejected, or when a requested dialect table
        /// was not available.
        let degraded: Bool
        let notes: [String]
    }

    /// §4.3's selection rules, stated in full:
    ///
    /// ```
    /// dialect == .default  → the dialect-agnostic tables only
    /// dialect has a table  → those + that dialect's (when conditional tables
    ///                        are admitted by policy)
    /// dialect has no table → those; a note is emitted
    /// ```
    ///
    /// Selection never blocks and never falls back to *another region's*
    /// table: applying an eastern table to a Doteli speaker would introduce
    /// errors that were not in the input, the one direction a canonicalizer
    /// must never move.
    ///
    /// `policy.includeConditionalTables` defaults to false. T-062 marks every
    /// region-marked slice `conditional` pending the native-speaker answers
    /// N1–N14, so a dialect table is loaded (it is data) but not consulted
    /// until that flag is set deliberately.
    func selection(for dialect: DialectLabel,
                   policy: DialectCanonicalizer.Policy) -> Selection {
        var consulted: [VariantTable] = []
        var notes = loadIssues
        var degraded = hasLoadDegradation

        /// Per-table fail-closed: a rejected table canonicalizes nothing; the
        /// rest of the set still runs. D-4 fails the *table*, not the set —
        /// §9.2 chose one file per region precisely so this is the granularity.
        func admit(_ table: VariantTable?) {
            guard let table else { return }
            let issues = table.issues()
            guard issues.isEmpty else {
                notes.append("table_rejected:\(table.tableID):\(issues.count)")
                degraded = true
                return
            }
            let inert = table.inertEntryCount(policy: policy)
            if inert > 0 {
                notes.append("inert_entries:\(table.tableID):\(inert)")
            }
            consulted.append(table)
        }

        admit(orthographic)
        admit(panRegional)
        admit(sttReductions)

        if dialect != .default {
            if dialectTables[dialect] == nil {
                notes.append("dialect_table_absent:\(dialect.rawValue)")
            } else if policy.includeConditionalTables {
                admit(dialectTables[dialect])
            } else {
                notes.append("dialect_table_conditional:\(dialect.rawValue)")
            }
        }
        return Selection(tables: consulted, degraded: degraded, notes: notes)
    }

    /// A stable revision anchor for `CanonicalizationResult.tableRevision`.
    ///
    /// Built from the tables' own identities, statuses and rules, so a content
    /// change moves it without anyone remembering to bump a version. A 64-bit
    /// FNV-1a digest over the ordered rules — deliberately not a cryptographic
    /// hash: this anchors an evidence pack, it does not attest integrity.
    var revision: String {
        var lines: [String] = []
        for table in tablesInStableOrder {
            lines.append("\(table.tableID)|\(table.generation.status)|\(table.entries.count)")
            for entry in table.entries {
                lines.append("\(entry.id)|\(entry.kindRaw)|\(entry.variant)\(entry.canonical)|\(entry.status.rawValue)")
            }
        }
        guard !lines.isEmpty else { return "none" }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in lines.joined(separator: "\n").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let status = orthographic?.generation.status
            ?? panRegional?.generation.status
            ?? "none"
        return "\(status)#\(String(hash, radix: 16))"
    }

    private var tablesInStableOrder: [VariantTable] {
        var ordered: [VariantTable] = []
        if let orthographic { ordered.append(orthographic) }
        if let panRegional { ordered.append(panRegional) }
        if let sttReductions { ordered.append(sttReductions) }
        ordered.append(contentsOf: dialectTables.keys
            .sorted { $0.rawValue < $1.rawValue }
            .compactMap { dialectTables[$0] })
        return ordered
    }

    // MARK: Loading

    /// Bundle subdirectory for the shipped tables. `ios/project.yml` declares
    /// `ElderlyAssistant/Resources/VariantTables` as a folder reference, so the
    /// directory lands in the bundle under this name.
    static let resourceSubdirectory = "VariantTables"

    static let orthographicResourceName = "canonical-orthographic"
    static let panRegionalResourceName = "canonical-panregional"
    static let sttReductionsResourceName = "canonical-stt-reductions"

    /// Resource name per dialect: the file is named for the label it declares,
    /// so adding a region is dropping in a file.
    static func resourceName(for dialect: DialectLabel) -> String {
        "canonical-\(dialect.rawValue)"
    }

    /// Loads the shipped table set. Never throws and never fails hard: a
    /// missing or undecodable file is recorded in `loadIssues` and the set is
    /// still usable — fail-soft is the design's rule (§8.7).
    static func load(bundle: Bundle = .main) -> VariantTableSet {
        var issues: [String] = []

        func loadTable(_ name: String) -> VariantTable? {
            guard let url = resourceURL(name: name, bundle: bundle) else {
                issues.append("\(resourceAbsentPrefix)\(name)")
                return nil
            }
            do {
                let data = try Data(contentsOf: url)
                return try JSONDecoder().decode(VariantTable.self, from: data)
            } catch {
                issues.append("\(resourceUndecodablePrefix)\(name)")
                return nil
            }
        }

        // A dialect table is loaded only for a label this binary knows; an
        // unexpected file in the directory changes nothing. Structurally
        // corrupt content is kept and reported when the table is selected, so
        // a rejected region does not empty the set.
        //
        // The filename/declaration cross-check is the one integrity rule here
        // that is not the designer's, and it is a REFUSAL rather than a note:
        // a file that ships as `canonical-eastern` while declaring no dialect
        // (or another one) would otherwise be consulted as the pan-regional
        // set — applying one region's rewrites to every speaker. A mismatch is
        // therefore dropped from the set and reported as degradation. This
        // check is not hypothetical: it caught `canonical-eastern.json`
        // shipping without its `dialect` field during this task's own build.
        var dialectTables: [DialectLabel: VariantTable] = [:]
        for label in DialectLabel.allCases where label != .default {
            let name = resourceName(for: label)
            guard let table = loadTable(name) else { continue }
            guard table.dialectRaw == label.rawValue else {
                issues.append("\(resourceDialectMismatchPrefix)\(name)")
                continue
            }
            dialectTables[label] = table
        }

        return VariantTableSet(orthographic: loadTable(orthographicResourceName),
                               panRegional: loadTable(panRegionalResourceName),
                               sttReductions: loadTable(sttReductionsResourceName),
                               dialectTables: dialectTables,
                               loadIssues: issues)
    }

    /// Process-wide cache for the interpreter hot path (static let is lazily
    /// initialised once, thread-safely), mirroring
    /// `DialectLexicon.bundledCached`.
    static let bundled: VariantTableSet = load()

    /// Folder reference first, flat fallback second: both bundling styles
    /// resolve, so a project-format change cannot silently empty the set.
    private static func resourceURL(name: String, bundle: Bundle) -> URL? {
        bundle.url(forResource: name,
                   withExtension: "json",
                   subdirectory: resourceSubdirectory)
            ?? bundle.url(forResource: name, withExtension: "json")
    }
}

// MARK: - Safety freeze

/// §4.7's frozen material, and the matcher the losslessness invariant is
/// stated over.
///
/// **This is the extracted-as-data half of the safety gate.** The design asks
/// for the gate to be computed by "calling the *shipped* matchers — not a
/// re-implementation — so the gate cannot drift from the net it protects".
/// The net's lists are `private` to `CommandRouter`, so the reference copy
/// lives here, organised list-for-list and matcher-for-matcher against
/// `CommandRouter.routeSafetyNet` (`:1493-1536`), with the line numbers on
/// each list. `DialectCanonicalizerTests` pins every member against the
/// literals, so a drift between the two is a test failure — which is the
/// property that matters until the design's T-077 repeats the check against
/// the shipped matchers themselves (that is gap G-5, explicitly out of this
/// task's scope).
///
/// Matcher semantics are the net's own:
///   - `containsPhrase(_:in:)` (`CommandRouter.swift:1439`) is a substring
///     test over the lowercased transcript. The emergency list, the ack
///     phrases and the denial phrases all use it.
///   - `containsToken(_:in:)` (`:1448`) splits on
///     `whitespacesAndNewlines ∪ punctuationCharacters` and compares whole
///     tokens. `ackTokens` uses it — whole-token *because* `खाए` sits inside
///     `नखाए`, so a containment match would turn a refusal into a medication
///     acknowledgement.
enum CanonicalSafetyFreeze {

    // MARK: The frozen material (§4.7), list for list

    /// The emergency list — `CommandRouter.swift:1468-1473`, 7 English + 10
    /// Nepali, matched by `containsPhrase`.
    static let emergencyList: [String] = [
        "help", "emergency", "i fell", "fell down", "chest pain",
        "can't breathe", "cant breathe",
        "मद्दत", "सहयोग गर", "बचाउ", "आपतकाल", "लडेँ", "लडें",
        "लड्नुभयो", "सास फेर्न सकिन", "सास फेर्न गाह्रो", "छाती दुख्यो"
    ]

    /// The denial guard — `CommandRouter.swift:1508-1512`, matched by
    /// `containsPhrase`, and checked BEFORE the ack list because refusal words
    /// contain ack words as substrings (`नखाए` ⊃ `खाए`, `भएन` ⊃ `भयो`).
    static let denialPhrases: [String] = [
        "i didn't", "i did not", "not yet", "haven't", "havent",
        "औषधि खाएको छैन", "औषधी खाएको छैन", "खाएको छैन",
        "नखाए", "नखाएको", "लिएको छैन", "भएन", "छैन"
    ]

    /// The medication-acknowledgement phrases — `CommandRouter.swift:1519-1527`,
    /// matched by `containsPhrase`.
    static let acknowledgementPhrases: [String] = [
        "i took", "i've taken", "ive taken", "took my medication",
        "took my medicine", "taken my medication", "taken my medicine",
        "yes i took it",
        "औषधि खाएँ", "औषधि खाए", "औषधी खाएँ", "औषधी खाए",
        "दवाई खाएँ", "दवाई खाए", "दबाइ खाएँ", "दबाइ खाए",
        "औषधि लिएको छु", "औषधी लिएको छु", "दवाई लिएको छु",
        "लिइसकेँ", "लिइसकें", "खाइसकेँ", "खाइसकें"
    ]

    /// The acknowledgement tokens — `CommandRouter.swift:1528-1529`, matched
    /// by `containsToken` (whole-token). `खाए` and `भयो` are the two the
    /// containment hazard is named for.
    static let acknowledgementTokens: [String] = [
        "done", "taken", "took", "ate",
        "खाएँ", "खाए", "भयो"
    ]

    /// The negation and polarity markers of §4.7: `न`, the `न-` prefixed class,
    /// `नखाए`, `होइन`, `भएन`, `छैन`, `पर्दैन`, the negative-verb class, and the
    /// yes-side polarity tokens the confirmation flow reads.
    ///
    /// Used only by the authoring-time validator's attached-form signature;
    /// the *matching* the gate is stated over uses the lists above.
    ///
    /// The yes/no tokens are here rather than in a list of their own because
    /// `CommandRouter.isYesResponse` / `.isNoResponse` (`:2620-2638`) are a
    /// ROUTING decision: a rule that turned `हो` into `होइन` (or dropped
    /// `छैन`) would silently answer a medication confirmation the other way.
    /// `हो`/`हजुर` are single-scalar, so they are matched whole-token only —
    /// which is what lets `गर्नुहोस्` (which contains `हो`) stay legal.
    static let negationMarkers: Set<String> = [
        "न", "नखाए", "नखाएको", "होइन", "होईन", "होइनन्", "भएन", "छैन", "पर्दैन",
        "गरेन", "दिएन", "आएन", "थिएन", "हुँदैन", "सक्दिन", "दिँदिन",
        "नगर", "नलिन", "नखान", "नआए", "नभए",
        "हो", "हजुर"
    ]

    /// Every list matched by `containsPhrase` (substring).
    static var substringLists: [String] {
        emergencyList + acknowledgementPhrases + denialPhrases
    }

    /// Every list matched by `containsToken` (whole-token).
    static var tokenList: [String] { acknowledgementTokens }

    // MARK: Row-level gate (§4.7's invariant)

    /// The net's clauses, in `routeSafetyNet`'s own evaluation order.
    ///
    /// The invariant is stated over CLAUSES rather than over the individual
    /// list members, because a clause is what the net computes:
    /// `emergencyPhrases.contains(where: { containsPhrase($0, in: text) })` is
    /// one Bool, and that Bool is the whole decision. Member identity is not
    /// part of any decision the net makes.
    ///
    /// This is not a weakening — it is the correct granularity, and the
    /// difference is load-bearing for a rule the design ASKS to ship:
    /// `औषधी → औषधि` (T-062's halanta drift) moves a match from the member
    /// `औषधी खाए` to the member `औषधि खाए`. Both members are in the ack list,
    /// so the ack clause fires before and after and the medication flow cannot
    /// change; a member-level comparison would have refused a correct rule and
    /// failed a correct table. The clause set still catches every hazard §4.7
    /// names, in both directions, because all of them change which CLAUSE
    /// fires: `नखाए → खाए` moves denial → ack, and `भया → भयो` moves nothing →
    /// ack.
    enum SafetyClause: String, Sendable, CaseIterable {
        case emergency
        case denial
        case acknowledgementPhrase
        case acknowledgementToken
    }

    /// The clauses the shipped matchers would fire on, computed with the
    /// shipped semantics — substring for the three phrase lists, whole-token
    /// for `acknowledgementTokens`.
    static func matchedClauses(in text: String) -> Set<SafetyClause> {
        let matcherText = folded(text)
        let rowTokens = Set(tokens(of: matcherText))
        var found: Set<SafetyClause> = []
        if emergencyList.contains(where: { matcherText.contains($0) }) {
            found.insert(.emergency)
        }
        if denialPhrases.contains(where: { matcherText.contains($0) }) {
            found.insert(.denial)
        }
        if acknowledgementPhrases.contains(where: { matcherText.contains($0) }) {
            found.insert(.acknowledgementPhrase)
        }
        if acknowledgementTokens.contains(where: { rowTokens.contains($0) }) {
            found.insert(.acknowledgementToken)
        }
        return found
    }

    /// The text every matcher compares against: lowercased, ends trimmed,
    /// interior whitespace runs collapsed to one space.
    ///
    /// `route()` does exactly this to the transcript before its own emergency
    /// check (`CommandRouter.swift:606-620` — the STT joins per-segment text
    /// with single spaces, so multi-segment utterances arrive with interior
    /// runs), and `routeSafetyNet` trims. The phrase lists are all
    /// single-spaced, so the fold can only turn a miss into a match, and there
    /// is no text for which the net matches and this does not.
    ///
    /// Folding HERE cannot make the invariant lenient: both texts being
    /// compared are folded the same way, so a rule that introduced a
    /// multi-space emergency phrase — an introduction clause (b) is meant to
    /// catch — is caught rather than waved through, and a legal rule's clause
    /// sets still agree.
    private static func folded(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// §4.7's invariant, stated as one predicate: the clause set is identical
    /// for both texts, with clause (a) (nothing removed — a rule that quietly
    /// eats a distress phrase) and clause (b) (nothing introduced — the
    /// `नखाए → खाए` class) both covered by set equality.
    ///
    /// It runs over the shipped matcher semantics above, so a failing row is a
    /// safety regression, not an accuracy one.
    static func isLossless(original: String, canonical: String) -> Bool {
        matchedClauses(in: canonical) == matchedClauses(in: original)
    }

    // MARK: The rest of the keyword layer

    // §4.7 freezes the SAFETY NET. These lists are the other half of the
    // keyword layer: not safety-critical, but they DECIDE ROUTING, so this
    // section exists to answer "would this rewrite move an utterance into, or
    // out of, a routing branch?" — the class the user's "no routing changes"
    // constraint is about.
    //
    // MEASURED, not assumed (offscreen harness over the shipped banks,
    // 2026-09-15): Swift's `String.contains` matches only at GRAPHEME CLUSTER
    // boundaries. `वाट्सएप` therefore matches inside `वाट्सएपमा` (boundary at
    // scalar 0) but NOT inside `ह्वाट्सएपमा`, where it starts mid-cluster after
    // the `ह्` conjunct — so the pan-regional rule
    // `ह्वाट्सएपमा → वाट्सएपमा` moves an utterance INTO the sensitive-call
    // match, and `isKeywordLayerLossless` is false for it. (A scalar-based
    // matcher — Python's `in`, or `String.range(of:)`-free byte search — would
    // have said the opposite. Do not re-derive this by eye; run the harness.)
    //
    // That rule ships anyway, and the reason is the composition, not a
    // loophole: the router never sees canonical text (D-1/§4.6 —
    // `safetyNetInput` and `pickerBrainInput` are the original), so a clause
    // set computed over the canonical form is not a routing input at all. The
    // invariant is kept because it is the authoring gate for the day someone
    // changes that composition, and the exception is PINNED AS A FAILING CASE
    // in the tests (`testLosslessnessTracksTheKeywordLayerNotJustTheNet`) so it
    // cannot be forgotten: if canonical text ever reaches the router, that test
    // is the one that already knows why it must not.

    /// `CommandRouter.swift:1482-1486`, matched by `containsPhrase`.
    static let sensitiveCallPhrases: [String] = [
        "call", "phone", "facetime", "messenger", "whatsapp",
        "फोन", "कल", "भिडियो कल", "म्यासेन्जर", "व्हाट्सएप", "वाट्सएप"
    ]

    /// `CommandRouter.swift:1412-1416`, matched by `containsPhrase`.
    static let briefingPhrases: [String] = [
        "read me my briefing", "read my briefing", "tell me my briefing",
        "मेरो ब्रीफिङ सुनाऊ", "ब्रीफिङ सुनाऊ",
        "मेरो बिहानको सारांश सुनाऊ", "बिहानको सारांश सुनाऊ",
        "mero briefing sunau", "bihanko sarsang sunau"
    ]

    /// `CommandRouter.swift:1426-1434`, matched by `containsPhrase`.
    static let newsPhrases: [String] = [
        "read me the news", "read the news", "tell me the news",
        "what's the news", "whats the news", "what is the news",
        "समाचार सुनाऊ", "समाचार सुनाउनुहोस्", "समाचार पढ",
        "खबर सुनाऊ", "खबर सुनाउनुहोस्", "खबर पढ",
        "samachar sunau", "samachar sunaunuhos", "khabar sunau"
    ]

    /// `CommandRouter.isYesResponse` (`:2620-2625`), matched by `containsToken`.
    static let yesTokens: [String] = [
        "yes", "yeah", "yep", "yup", "correct", "हो", "हजुर"
    ]

    /// `CommandRouter.isNoResponse` (`:2632-2636`), matched by `containsToken`.
    static let noTokens: [String] = [
        "no", "nope", "wrong", "छैन", "होइन", "होइनन्"
    ]

    /// Every routable list outside the safety net, with its matcher.
    static var keywordLayerPhraseLists: [String] {
        sensitiveCallPhrases + briefingPhrases + newsPhrases
    }

    static var keywordLayerTokenLists: [String] { yesTokens + noTokens }

    /// Every clause of the keyword layer, safety net included.
    enum KeywordClause: String, Sendable, CaseIterable {
        case emergency
        case denial
        case acknowledgementPhrase
        case acknowledgementToken
        case sensitiveCall
        case briefing
        case news
        case yes
        case no
    }

    /// The keyword-layer clauses the shipped matchers would fire on.
    static func matchedKeywordClauses(in text: String) -> Set<KeywordClause> {
        let matcherText = folded(text)
        let rowTokens = Set(tokens(of: matcherText))
        var found: Set<KeywordClause> = []
        let net = matchedClauses(in: matcherText)
        if net.contains(.emergency) { found.insert(.emergency) }
        if net.contains(.denial) { found.insert(.denial) }
        if net.contains(.acknowledgementPhrase) { found.insert(.acknowledgementPhrase) }
        if net.contains(.acknowledgementToken) { found.insert(.acknowledgementToken) }
        if sensitiveCallPhrases.contains(where: { matcherText.contains($0) }) {
            found.insert(.sensitiveCall)
        }
        if briefingPhrases.contains(where: { matcherText.contains($0) }) {
            found.insert(.briefing)
        }
        if newsPhrases.contains(where: { matcherText.contains($0) }) { found.insert(.news) }
        if yesTokens.contains(where: { rowTokens.contains($0) }) { found.insert(.yes) }
        if noTokens.contains(where: { rowTokens.contains($0) }) { found.insert(.no) }
        return found
    }

    /// The routing-level invariant: the rewrite changes no keyword-layer
    /// clause, in either direction, in any list — the safety net's clauses and
    /// every routing clause beyond them.
    ///
    /// Deliberately wider than `isLossless`, which is §4.7's invariant stated
    /// over the net and stays exactly that so it can be audited against §4.7
    /// line by line. This is the same property extended to the whole keyword
    /// layer: the call block, the briefing/news stage and the yes/no
    /// confirmation flow all decide on these clauses, and none of them is in
    /// §4.7's list.
    ///
    /// It is an AUTHORING GATE, not a description of the shipped behaviour: one
    /// shipped rule (`ह्वाट्सएपमा → वाट्सएपमा`) is false here, and it is false
    /// for a real reason (grapheme-cluster anchoring — see the note above
    /// `sensitiveCallPhrases`). What makes that rule harmless is the
    /// COMPOSITION: `CommandRouter` reads the original transcript, always (D-1),
    /// so no clause set computed over canonical text is a routing input. A
    /// failing case here therefore means "this rule would change routing in a
    /// world where the router saw canonical text", which is precisely the
    /// question a future wiring change has to answer.
    static func isKeywordLayerLossless(original: String, canonical: String) -> Bool {
        matchedKeywordClauses(in: canonical) == matchedKeywordClauses(in: original)
    }

    // MARK: Entry-level check (§4.3 `negationMarkerTouched`)

    /// True when a rule rewrites, produces or consumes frozen material — the
    /// machine-checkable form of D-1. A hit is a structural error, not a
    /// warning, and refuses the whole table (§4.3).
    ///
    /// Three tests:
    ///
    /// 1. **Frozen-material hit** — a runnable list entry appears inside
    ///    `variant` or `canonical`, with that list's own matcher. This catches
    ///    the `खाए` ⊂ `नखाए` class head-on: the entry `नखाए → खाए` carries the
    ///    denial phrase `नखाए` on its left, and `भया → भयो` carries the
    ///    acknowledgement token `भयो` on its right.
    /// 2. **Whole-token hit** — a token of either side is one of the
    ///    whole-token entries (§4.7: no rule may map a form onto one of these,
    ///    or away from one of these).
    /// 3. **Attached-marker drift** — the negation signature of the two sides
    ///    differs, catching a marker attached as a prefix or suffix (`नखाए`,
    ///    `खाएन`) that one side carries and the other does not.
    ///
    /// It never fires for a rewrite that leaves polarity and the safety
    /// vocabulary alone, which is every rule the shipped seed tables carry.
    static func touches(variant: String, canonical: String) -> Bool {
        for side in [variant, canonical] {
            let lower = folded(side)
            if substringLists.contains(where: { lower.contains($0) }) { return true }
            let sideTokens = Set(tokens(of: lower))
            if tokenList.contains(where: { sideTokens.contains($0) }) { return true }
            if negationMarkers.contains(where: { sideTokens.contains($0) }) { return true }
        }
        return negationSignature(of: variant) != negationSignature(of: canonical)
    }

    /// The negation markers `text` carries, including attached forms: a token
    /// contributes a marker when the token IS the marker, when a multi-scalar
    /// marker is attached to it as a prefix or a suffix, or when the bare `न`
    /// is attached as a prefix.
    private static func negationSignature(of text: String) -> Set<String> {
        var found: Set<String> = []
        for token in tokens(of: text) {
            if negationMarkers.contains(token) {
                found.insert(token)
                continue
            }
            for marker in negationMarkers where marker.unicodeScalars.count > 1 {
                if token.hasPrefix(marker) || token.hasSuffix(marker) {
                    found.insert(marker)
                }
            }
            if token.unicodeScalars.count > 1, token.hasPrefix("न") {
                found.insert("न")
            }
        }
        return found
    }

    /// The net's token split: `whitespacesAndNewlines ∪ punctuationCharacters`,
    /// lowercased, empties dropped.
    static func tokens(of text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: tokenSeparators)
            .filter { !$0.isEmpty }
    }

    /// The exact separator set `CommandRouter.containsToken` splits on.
    static let tokenSeparators: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.formUnion(.punctuationCharacters)
        return set
    }()
}

// MARK: - Canonicalizer

/// The pre-intent normalizer (§4.2). Pure, synchronous, non-throwing and
/// non-retryable by construction: a table lookup over a bounded string, with
/// no I/O, no model and no async boundary, so the composition adds no new
/// failure mode to the interpreter's completion contract.
enum DialectCanonicalizer {

    /// §4.2's policy, plus the gate this phase needs for the unsettled
    /// dialect inventory.
    struct Policy: Equatable, Sendable {
        /// Whether any rule may fire at all. False is the kill switch (§6.6)
        /// and the A/B control arm.
        var enabled: Bool = true
        /// When true, only `orthographic` rules run — the conservative arm,
        /// used before per-dialect tables clear review.
        var orthographicOnly: Bool = false
        /// When true, a region-marked table may be consulted. Default FALSE:
        /// T-062 files every region-marked slice `conditional` pending the
        /// native-speaker answers N1–N14, and a canonicalizer keyed on an
        /// unsettled inventory must not act on it (D-9, R-7).
        var includeConditionalTables: Bool = false

        init(enabled: Bool = true,
             orthographicOnly: Bool = false,
             includeConditionalTables: Bool = false) {
            self.enabled = enabled
            self.orthographicOnly = orthographicOnly
            self.includeConditionalTables = includeConditionalTables
        }

        /// The shipped runtime policy: inert unless BOTH the compile-time gate
        /// and the persisted toggle are on.
        ///
        /// `IntentEncoderFeature.isEnabled` is a compilation condition that is
        /// false on a non-gated build, so canonicalization cannot alter a
        /// release build by accident — the same shape that keeps the encoder
        /// out of one. `CanonicalizerPreferences.canonicalizerEnabled` reads an
        /// absent key as false, so a gated build still ships unchanged
        /// behaviour until someone opts in.
        static func runtime(defaults: UserDefaults = .standard,
                            isCompiledIn: Bool = IntentEncoderFeature.isEnabled,
                            isToggleOn: Bool? = nil) -> Policy {
            let toggle = isToggleOn
                ?? CanonicalizerPreferences(defaults: defaults).canonicalizerEnabled
            // The SHIPPED gate function, not a copy of it
            // (`IntentEncoderWiring.isServingEnabled`), so "both gates are
            // required" cannot drift between the encoder's own switch and
            // this one.
            let serving = IntentEncoderWiring.isServingEnabled(isCompiledIn: isCompiledIn,
                                                               isToggleOn: toggle)
            return Policy(enabled: serving)
        }
    }

    /// Rewrites attested variant surface forms onto canonical forms (§4.2).
    ///
    /// `transcript` is expected to be `InputSanitiser.sanitise(_:level:.quarantine)`
    /// output: the sanitiser runs FIRST (§4.6), and this function deliberately
    /// does not sanitise — composing the two here would put a table lookup
    /// upstream of the injection boundary and let a rewrite resurrect text the
    /// 200-character clamp had removed.
    ///
    /// Returns the canonical transcript plus per-application provenance. The
    /// result's `canonical` is byte-identical to `transcript` when the policy
    /// is off, the input is empty, or no rule matches.
    static func canonicalize(_ transcript: String,
                             dialect: DialectLabel,
                             tables: VariantTableSet,
                             policy: Policy = Policy()) -> CanonicalizationResult {
        let revision = tables.revision
        guard policy.enabled, !transcript.isEmpty else {
            return CanonicalizationResult(canonical: transcript,
                                          applications: [],
                                          tableRevision: revision,
                                          degraded: false,
                                          notes: [])
        }

        let selection = tables.selection(for: dialect, policy: policy)
        var work = transcript
        var edits: [Edit] = []

        // Stage 1 — O-1 NFC and O-5 digit folding, then the orthographic table.
        // The built-ins are total, closed mappings with no authored content, so
        // they are code rather than table rows; they are still recorded as
        // applications, because `applications` is never empty when
        // `canonical != original` (D-5) and because dropping them would make a
        // coverage number in the §14 evidence pack a lie.
        applyCharacterTransform(NFCTransform(),
                                ruleID: "builtin-nfc-precomposition",
                                tableID: VariantTableSet.orthographicResourceName,
                                dialect: nil,
                                kind: .orthographic,
                                work: &work, edits: &edits)
        applyCharacterTransform(DevanagariDigitTransform(),
                                ruleID: "builtin-devanagari-digit-fold",
                                tableID: VariantTableSet.orthographicResourceName,
                                dialect: nil,
                                kind: .orthographic,
                                work: &work, edits: &edits)

        let ordered = orderedTables(selection.tables)
        for stage in CanonicalizationKind.allCases.sorted(by: { $0.stageOrder < $1.stageOrder }) {
            applyEntries(liveEntries(tables: ordered, stage: stage, policy: policy),
                         work: &work,
                         edits: &edits)
        }

        let applications = edits
            .sorted { $0.canonicalRange.lowerBound < $1.canonicalRange.lowerBound }
            .map(\.application)

        return CanonicalizationResult(canonical: work,
                                      applications: applications,
                                      tableRevision: revision,
                                      degraded: selection.degraded,
                                      notes: selection.notes)
    }

    /// Stage 3/4 precedence is "dialect table, then pan-regional" (§4.2);
    /// stages 1/2 keep the set's own order. Both are the selection's list,
    /// re-anchored — never a second copy of the tables.
    private static func orderedTables(_ tables: [VariantTable])
    -> (stages12: [VariantTable], stages34: [VariantTable]) {
        let dialect = tables.filter { $0.dialect != nil }
        let agnostic = tables.filter { $0.dialect == nil }
        return (tables, dialect + agnostic)
    }

    private static func liveEntries(tables: (stages12: [VariantTable], stages34: [VariantTable]),
                                    stage: CanonicalizationKind,
                                    policy: Policy) -> [LiveEntry] {
        let ordered = stage.stageOrder <= 2 ? tables.stages12 : tables.stages34
        var live: [LiveEntry] = []
        for table in ordered {
            for entry in table.applicableEntries(policy: policy) where entry.kind == stage {
                live.append(LiveEntry(entry: entry,
                                      tableID: table.tableID,
                                      dialect: table.dialect))
            }
        }
        return live
    }

    // MARK: Rewrite machinery

    /// One recorded rewrite, in canonical coordinates. Edits never overlap — a
    /// rule may not rewrite a region another rule produced — which is what
    /// makes both the offset translation and the provenance exact, and what
    /// stops two rules from fighting over one word.
    struct Edit: Equatable, Sendable {
        var canonicalRange: Range<Int>
        let originalRange: Range<Int>
        let ruleID: String
        let tableID: String
        let dialect: DialectLabel?
        let kind: CanonicalizationKind
        let original: String
        let canonical: String

        var application: CanonicalVariantApplication {
            CanonicalVariantApplication(ruleID: ruleID,
                                        tableID: tableID,
                                        dialect: dialect,
                                        kind: kind,
                                        originalRange: originalRange,
                                        canonicalRange: canonicalRange,
                                        original: original,
                                        canonical: canonical)
        }
    }

    /// A table entry ready to fire: its provenance resolved once.
    struct LiveEntry: Equatable, Sendable {
        let entry: VariantTableEntry
        let tableID: String
        let dialect: DialectLabel?

        var needle: String { entry.variant.lowercased() }
    }

    /// A character-level total transform for the built-in passes. Returning
    /// the input character means "no change".
    protocol CharacterTransform {
        func replacement(for character: Character) -> String
    }

    /// O-1 — NFC precomposition. Cheap, idempotent, no semantic risk; the same
    /// intent as `NepaliTextNormalizer.swift:35`, applied here because the
    /// model's input needs a stabilised surface before any table lookup.
    struct NFCTransform: CharacterTransform {
        func replacement(for character: Character) -> String {
            String(character).precomposedStringWithCanonicalMapping
        }
    }

    /// O-5 — Devanagari digit folding, the same mapping as
    /// `NepaliTextNormalizer.swift:26-29` but applied for the *model's*
    /// benefit rather than the cache key's.
    struct DevanagariDigitTransform: CharacterTransform {
        private static let digits: [Character: Character] = [
            "०": "0", "१": "1", "२": "2", "३": "3", "४": "4",
            "५": "5", "६": "6", "७": "7", "८": "8", "९": "9"
        ]
        func replacement(for character: Character) -> String {
            guard let mapped = Self.digits[character] else { return String(character) }
            return String(mapped)
        }
    }

    /// Applies a character-level transform, coalescing each run of changed
    /// characters into one edit so provenance reads as one rewrite per region
    /// rather than one per scalar.
    static func applyCharacterTransform<T: CharacterTransform>(_ transform: T,
                                                              ruleID: String,
                                                              tableID: String,
                                                              dialect: DialectLabel?,
                                                              kind: CanonicalizationKind,
                                                              work: inout String,
                                                              edits: inout [Edit]) {
        var replacements: [(range: Range<Int>, original: String, canonical: String)] = []
        var runStart: Int?
        var runOriginal = ""
        var runCanonical = ""
        var offset = 0

        for character in work {
            let original = String(character)
            let canonical = transform.replacement(for: character)
            // SCALAR-wise, not `canonical != original`: Swift's String equality
            // is canonical-equivalence, so a decomposed `e` + U+0301 compares
            // EQUAL to precomposed `é` — and a precomposition transform that
            // used it would silently rewrite nothing, which is the exact case
            // it exists for (measured by the offline harness, 2026-09-15:
            // "cafe\u{0301}" came back with the combining mark still in it and
            // an empty `applications`).
            if !canonical.unicodeScalars.elementsEqual(original.unicodeScalars) {
                if runStart == nil { runStart = offset }
                runOriginal += original
                runCanonical += canonical
            } else if let start = runStart {
                replacements.append((start..<(start + runOriginal.unicodeScalars.count),
                                     runOriginal, runCanonical))
                runStart = nil
                runOriginal = ""
                runCanonical = ""
            }
            offset += original.unicodeScalars.count
        }
        if let start = runStart {
            replacements.append((start..<(start + runOriginal.unicodeScalars.count),
                                 runOriginal, runCanonical))
        }

        // Right to left, so an earlier replacement's offsets stay valid.
        for replacement in replacements.reversed() {
            applyEdit(canonicalRange: replacement.range,
                      replacement: replacement.canonical,
                      originalText: replacement.original,
                      ruleID: ruleID,
                      tableID: tableID,
                      dialect: dialect,
                      kind: kind,
                      work: &work,
                      edits: &edits)
        }
    }

    /// Applies every live entry once, scanning left to right: at each position
    /// the entries are tried in table order and the first match wins.
    ///
    /// A match must sit on a token boundary — the same boundary
    /// `containsToken` uses — so a rule can never rewrite half a word (O-6's
    /// hazard, §4.4) and can never rewrite a region another rule produced.
    /// This is also what keeps the output single-spaced by construction: a
    /// match consumes whole tokens, so removing one cannot leave a doubled
    /// separator, and §4.2's stage-5 re-collapse has nothing left to do.
    static func applyEntries(_ live: [LiveEntry],
                             work: inout String,
                             edits: inout [Edit]) {
        guard !live.isEmpty else { return }
        var cursor = work.startIndex
        while cursor < work.endIndex {
            let cursorOffset = scalarOffset(of: cursor, in: work)
            let haystack = foldedSearchText(work)
            var advanced = false
            for item in live {
                if let next = apply(item,
                                    fromOffset: cursorOffset,
                                    haystack: haystack,
                                    work: &work,
                                    edits: &edits) {
                    cursor = next
                    advanced = true
                    break
                }
            }
            if !advanced { cursor = work.index(after: cursor) }
        }
    }

    /// Finds the first boundary-valid, non-overlapping occurrence of the
    /// entry's variant at or after `fromOffset` and applies it. Returns the
    /// index just past the replacement, or nil when the entry does not match.
    private static func apply(_ item: LiveEntry,
                              fromOffset: Int,
                              haystack: String,
                              work: inout String,
                              edits: inout [Edit]) -> String.Index? {
        let needle = item.needle
        guard !needle.isEmpty else { return nil }
        var searchOffset = fromOffset

        while searchOffset < haystack.unicodeScalars.count {
            let from = stringIndex(atScalar: searchOffset, in: haystack)
            guard let found = haystack.range(of: needle, range: from..<haystack.endIndex) else {
                return nil
            }
            let range = scalarRange(found, in: haystack)
            let overlaps = edits.contains { $0.canonicalRange.overlaps(range) }
            if !overlaps, isTokenBounded(range, in: work) {
                let matched = String(work[stringIndex(atScalar: range.lowerBound, in: work)
                                           ..< stringIndex(atScalar: range.upperBound, in: work)])
                applyEdit(canonicalRange: range,
                          replacement: item.entry.canonical,
                          originalText: matched,
                          ruleID: item.entry.id,
                          tableID: item.tableID,
                          dialect: item.dialect,
                          kind: item.entry.kind ?? .orthographic,
                          work: &work,
                          edits: &edits)
                let end = range.lowerBound + item.entry.canonical.unicodeScalars.count
                return stringIndex(atScalar: end, in: work)
            }
            searchOffset = range.lowerBound + 1
        }
        return nil
    }

    /// Splices one replacement in and records it.
    ///
    /// Edits are held in canonical coordinates and never overlap, so the
    /// original range is a pure delta walk backwards over the edits that
    /// precede this one — §4.5's exact-substitution case, which is the one the
    /// design asks authoring to prefer precisely because it yields an exact
    /// span map.
    static func applyEdit(canonicalRange: Range<Int>,
                          replacement: String,
                          originalText: String,
                          ruleID: String,
                          tableID: String,
                          dialect: DialectLabel?,
                          kind: CanonicalizationKind,
                          work: inout String,
                          edits: inout [Edit]) {
        let originalRange = mapToOriginal(canonicalRange, edits: edits)
        let lo = stringIndex(atScalar: canonicalRange.lowerBound, in: work)
        let hi = stringIndex(atScalar: canonicalRange.upperBound, in: work)
        work = work.replacingCharacters(in: lo..<hi, with: replacement)

        let newCanonicalRange = canonicalRange.lowerBound
            ..< (canonicalRange.lowerBound + replacement.unicodeScalars.count)
        let delta = replacement.unicodeScalars.count - canonicalRange.count
        if delta != 0 {
            for index in edits.indices
            where edits[index].canonicalRange.lowerBound >= canonicalRange.upperBound {
                edits[index].canonicalRange = (edits[index].canonicalRange.lowerBound + delta)
                    ..< (edits[index].canonicalRange.upperBound + delta)
            }
        }
        edits.append(Edit(canonicalRange: newCanonicalRange,
                          originalRange: originalRange,
                          ruleID: ruleID,
                          tableID: tableID,
                          dialect: dialect,
                          kind: kind,
                          original: originalText,
                          canonical: replacement))
        if edits.count > 1 {
            edits.sort { $0.canonicalRange.lowerBound < $1.canonicalRange.lowerBound }
        }
    }

    /// Translates a canonical-coordinate range back into the original
    /// transcript's coordinates.
    ///
    /// Every runnable range is disjoint from every edit (the scan refuses
    /// overlaps), so this is exact: the offset shift is the sum of the length
    /// deltas of the edits that end at or before the range's start.
    static func mapToOriginal(_ range: Range<Int>, edits: [Edit]) -> Range<Int> {
        var delta = 0
        for edit in edits where edit.canonicalRange.upperBound <= range.lowerBound {
            delta += edit.canonicalRange.count - edit.originalRange.count
        }
        return (range.lowerBound - delta)..<(range.upperBound - delta)
    }

    /// The net's token boundary: a match must begin after a separator (or the
    /// string start) and end before one (or the string end), where a separator
    /// is `whitespacesAndNewlines ∪ punctuationCharacters` — the exact set
    /// `containsToken` splits on.
    static func isTokenBounded(_ range: Range<Int>, in text: String) -> Bool {
        let lo = stringIndex(atScalar: range.lowerBound, in: text)
        let hi = stringIndex(atScalar: range.upperBound, in: text)
        if lo > text.startIndex, !isSeparator(text[text.index(before: lo)]) { return false }
        if hi < text.endIndex, !isSeparator(text[hi]) { return false }
        return true
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            CanonicalSafetyFreeze.tokenSeparators.contains($0)
        }
    }

    /// The text a needle is searched in, case-folded with the net's own
    /// lowercasing.
    ///
    /// `lowercased()` is length-preserving for the alphabets these tables
    /// carry (Devanagari U+0900–U+097F and ASCII Latin), so folded offsets map
    /// 1:1 onto the working text. The count guard makes that assumption
    /// CHECKED rather than assumed: for a transcript carrying a scalar whose
    /// lowercase changes length, the folded view is not offset-compatible and
    /// the unfolded text is searched instead — case-sensitively, which is a
    /// narrower match, never a wrong-offset one.
    private static func foldedSearchText(_ text: String) -> String {
        let folded = text.lowercased()
        return folded.unicodeScalars.count == text.unicodeScalars.count ? folded : text
    }

    // MARK: Offsets (unicode scalars — the contract's span unit)

    /// `index`'s offset in Unicode scalars from the start of `text`.
    static func scalarOffset(of index: String.Index, in text: String) -> Int {
        text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: index)
    }

    static func scalarRange(_ range: Range<String.Index>, in text: String) -> Range<Int> {
        scalarOffset(of: range.lowerBound, in: text)
            ..< scalarOffset(of: range.upperBound, in: text)
    }

    /// The `String.Index` at `offset` Unicode scalars into `text`.
    ///
    /// `String.Index` is shared across a string's views, so the resulting
    /// index is valid for `text` itself. Every offset handled here came from a
    /// `range(of:)` result over the same (or a scalar-count-equal) string, so
    /// it always sits on a scalar boundary and can never split a Devanagari
    /// cluster.
    static func stringIndex(atScalar offset: Int, in text: String) -> String.Index {
        text.unicodeScalars.index(text.unicodeScalars.startIndex, offsetBy: offset)
    }
}

// MARK: - Kill switch

/// TG-12 Phase 1 — the persisted kill switch for canonicalization, the same
/// shape as `IntentEncoderPreferences` and `DialectBiasSettings`.
///
/// Defaults to OFF, and an absent key reads as false: canonicalization rewrites
/// the text a model reads, so serving it must be an explicit decision. The key
/// is deliberately namespaced away from the shipped preferences, so it can be
/// set or cleared from a debugger or a UITest launch argument without touching
/// a user-facing setting. `Policy.runtime` is also gated on
/// `IntentEncoderFeature.isEnabled`, so this toggle cannot switch
/// canonicalization on in a build that cannot compile the encoder path either.
final class CanonicalizerPreferences {
    static let canonicalizerEnabledKey = "canonicalizer.enabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// True only when someone has explicitly switched canonicalization on.
    var canonicalizerEnabled: Bool {
        guard defaults.object(forKey: Self.canonicalizerEnabledKey) != nil else { return false }
        return defaults.bool(forKey: Self.canonicalizerEnabledKey)
    }

    func setCanonicalizerEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.canonicalizerEnabledKey)
    }

    func reset() {
        defaults.removeObject(forKey: Self.canonicalizerEnabledKey)
    }
}

// MARK: - Composition seam

/// What the intent models are handed for one turn (§4.6).
///
/// The pair exists so the two consumers can never be confused for one another.
/// `modelInput` is the canonical transcript; `safetyNetInput` is the original,
/// always — D-1's invariant, made structural rather than documented. There is
/// no accessor that hands the canonical form to a safety consumer, which is the
/// property the design's rejected refactor ("canonicalize once at the top of
/// `route()` and let every stage share it") would have destroyed.
struct IntentTranscriptPair: Equatable, Sendable {
    /// The sanitised transcript exactly as the safety net sees it.
    let original: String
    /// The canonical transcript, ready for the encoder's tokenizer.
    let canonical: String
    let applications: [CanonicalVariantApplication]
    let degraded: Bool
    let tableRevision: String
    let notes: [String]
    /// [TG-12] The STT-error corrector's result for this turn, when the layer
    /// ran inside `IntentInputCanonicalization.prepare`. `nil` means "the
    /// corrector did not run" (a pair built by hand, an older caller) — NOT
    /// "it ran and found nothing", which is a result whose `mode` is `.off` or
    /// `.shadow`, or whose `applications` is empty.
    ///
    /// The result is carried whole rather than reduced to a string because a
    /// consumer needs three different things from it and they must not drift:
    /// the corrected text (`canonical` above is the corrected text
    /// CANONICALIZED), the per-token decisions (the debug readout) and the
    /// count-only metadata (the event).
    let correction: CorrectionResult?

    init(original: String,
         canonical: String,
         applications: [CanonicalVariantApplication] = [],
         degraded: Bool = false,
         tableRevision: String,
         notes: [String] = [],
         correction: CorrectionResult? = nil) {
        self.original = original
        self.canonical = canonical
        self.applications = applications
        self.degraded = degraded
        self.tableRevision = tableRevision
        self.notes = notes
        self.correction = correction
    }

    /// What the *intent model* reads. Identity to `original` while the
    /// canonicalizer is inert (compile gate off, toggle off, policy disabled,
    /// or no rule matched).
    ///
    /// [TG-12] This is the CANONICALIZED CORRECTED text: the corrector runs
    /// first (§4.6's order — typo-fix, then canonicalize, then the encoder), so
    /// the canonicalizer's input is `correction.corrected`, never `original`.
    /// While the corrector is off, `correction.corrected == original` and this
    /// expression is byte-for-byte the one that ran before the layer existed.
    var modelInput: String { canonical }

    /// [TG-12] The text the canonicalizer actually saw — the corrector's
    /// output, or `original` when the corrector did not run. Exposed so a
    /// consumer that must reason about the intermediate (a Phase-2 span
    /// remap, a debugger) reads it from the pair rather than re-running the
    /// corrector and hoping the two agree.
    var correctedInput: String { correction?.corrected ?? original }

    /// What the *keyword safety net* reads: the original, forever (D-1,
    /// `CommandRouter.routeSafetyNet`). Canonicalization may never gate,
    /// suppress, rewrite or delay what the net sees.
    var safetyNetInput: String { original }

    /// What the *picker brain* reads on a cascade escalation: the original
    /// sanitised transcript, not the canonical one (§4.6, evidence row E-17
    /// "HOLDS BY DESIGN"). The picker is a general-purpose LLM with no
    /// canonical-form training, so a variant table is evidence about *this*
    /// encoder's inputs, not about Qwen's; feeding it canonicalized text is an
    /// unmeasured intervention on the one rung that currently works, and it
    /// would make the §6 latency/quality comparison a comparison of two
    /// changes instead of one. The canonical form rides alongside in
    /// `canonical`, should a later task want that A/B.
    var pickerBrainInput: String { original }

    /// True when nothing was rewritten, so `modelInput == original`.
    ///
    /// [TG-12] BOTH layers have to be identity for the pair to be: a turn the
    /// corrector rewrote and the canonicalizer passed through is not an
    /// identity turn, and reporting it as one would tell the encoder (and the
    /// event) that the model input is the transcript when it is not.
    var isIdentity: Bool {
        applications.isEmpty && (correction?.isIdentity ?? true)
    }

    /// What the encoder emits when `isIdentity` is false: rule ids, table ids,
    /// kinds and counts, plus the table revision and the fixed-vocabulary
    /// notes. Never a variant form, a canonical form, or a word of the
    /// transcript (§6.6, NFR-016, R-9) — assembled by the same builder the
    /// canonicalization result uses, so the pair cannot disclose more than the
    /// result it came from.
    ///
    /// [TG-12] The corrector's own count-only keys are merged in on the same
    /// terms (A-16: buckets and row ids, never a surface form) — but only when
    /// the layer actually PARTICIPATED. A corrector that is off adds no keys:
    /// the metadata for a canonicalization-only turn stays exactly what it was
    /// before this layer existed (the seam's own invariant, and the reason a
    /// disabled layer cannot change the shape of an event).
    var observabilityMetadata: [String: String] {
        var metadata = canonicalizationMetadata
        if let correction, correction.mode != .off || correction.degraded {
            for (key, value) in correction.observabilityMetadata {
                metadata[key] = value
            }
        }
        return metadata
    }

    /// The canonicalizer's own payload, exactly what `observabilityMetadata`
    /// returned before the corrector existed. Kept as its own accessor because
    /// `encoder_input_canonicalized` is the CANONICALIZER's event: a turn the
    /// corrector rewrote and the canonicalizer passed through must not fire it,
    /// and when it does fire it must carry the canonicalization keys alone.
    var canonicalizationMetadata: [String: String] {
        CanonicalizationObservability.metadata(tableRevision: tableRevision,
                                               applications: applications,
                                               degraded: degraded,
                                               notes: notes)
    }

    /// The canonicalizer's half of `isIdentity`. The encoder's existing
    /// canonicalization event gates on this, so turning the corrector on cannot
    /// change when that event fires or what it says.
    var canonicalizationIsIdentity: Bool { applications.isEmpty }

    /// How a decoded span maps back onto the original transcript (§4.5).
    enum SpanMapping: Equatable, Sendable {
        /// The span lies in a region no rule touched; offsets are already
        /// original-relative.
        case untouched(Range<Int>)
        /// The span is entirely inside one application's `canonicalRange`; the
        /// map is exact (a substitution).
        case exact(Range<Int>)
        /// The span straddles application boundaries or overlaps a
        /// length-changing rewrite, so it was widened to the union of the
        /// affected applications.
        case widened(Range<Int>)

        var originalRange: Range<Int> {
            switch self {
            case .untouched(let range), .exact(let range), .widened(let range):
                return range
            }
        }

        /// §4.5's abstain rule: a widened span is safe for a substring match
        /// and unsafe for a resolution, so a span *required for a side-effecting
        /// action* (`contact` for call/send_message, `time` for set_reminder)
        /// that widens must make the interpreter abstain rather than resolve.
        /// Resolving a widened contact is the "calls the wrong person" hazard
        /// `NepaliTextNormalizer` refuses transliteration to avoid.
        var requiresAbstention: Bool {
            if case .widened = self { return true }
            return false
        }
    }

    /// §4.5's map, in full:
    ///
    /// ```
    /// no application overlaps      → untouched (shifted by any delta before it)
    /// contained in one application → that application's originalRange (exact)
    /// straddles applications       → union, widened
    /// overlaps a deletion          → union, widened
    /// ```
    ///
    /// Provided for the task that wires provenance into the encoder's span
    /// decoder. This task does not call it: while the canonicalizer is inert
    /// `applications` is empty and every span is `untouched`, and wiring a
    /// remap into a decoder that cannot yet see a canonical transcript would be
    /// an unmeasurable change (design §4.5, R-4).
    func originalRange(forCanonicalRange range: Range<Int>) -> SpanMapping {
        var delta = 0
        var overlapping: [CanonicalVariantApplication] = []
        for application in applications {
            if application.canonicalRange.overlaps(range) {
                overlapping.append(application)
            } else if application.canonicalRange.upperBound <= range.lowerBound {
                delta += application.canonicalRange.count - application.originalRange.count
            }
        }
        guard let first = overlapping.first else {
            return .untouched((range.lowerBound - delta)..<(range.upperBound - delta))
        }
        if overlapping.count == 1,
           first.canonicalRange.lowerBound <= range.lowerBound,
           first.canonicalRange.upperBound >= range.upperBound {
            return .exact(first.originalRange)
        }
        let lower = overlapping.map(\.originalRange.lowerBound).min() ?? range.lowerBound
        let upper = overlapping.map(\.originalRange.upperBound).max() ?? range.upperBound
        return .widened(lower..<upper)
    }
}

/// The composition seam between the sanitised transcript and the intent models
/// (§4.6). Constructed and available; inert until a later wiring task flips it
/// on.
enum IntentInputCanonicalization {

    /// Computes the pair for one turn.
    ///
    /// Callers pass `InputSanitiser.sanitise(_:level:.quarantine)` output — the
    /// sanitiser stays the injection boundary and stays first, so a table
    /// rewrite can never resurrect text the clamp removed (§4.6).
    ///
    /// With `policy.enabled == false` (the shipped default) this returns the
    /// sanitised transcript byte-identical as both `original` and `canonical`,
    /// with no applications: the seam is a pass-through and no downstream
    /// behaviour differs from before this file existed.
    ///
    /// [TG-12] ORDER (§4.6, addendum §3.1): CORRECT, then CANONICALIZE, then
    /// the encoder. The corrector sees the sanitised transcript and nothing
    /// else; the canonicalizer sees the corrector's output; `modelInput` is the
    /// result of both. The two layers share this one seam and the same
    /// compile gate, and a correction can never reach anything but the intent
    /// model: `original` — what the keyword safety net, the emergency path and
    /// the medication-acknowledgement path read — is still the sanitised
    /// transcript, untouched by either layer, and `safetyNetInput` still hands
    /// it over.
    ///
    /// The corrector's policy is resolved HERE, from the lexicon that will
    /// actually be read, rather than taken as a defaulted argument evaluated
    /// before the caller's lexicon is known: a threshold fitted on one bank and
    /// applied with another is the drift A-12 exists to prevent. Passing
    /// `correctionPolicy` explicitly (tests, a future settings surface) skips
    /// that resolution and uses exactly what was passed.
    static func prepare(sanitisedTranscript: String,
                        dialect: DialectLabel = DialectPreference.persisted(),
                        tables: VariantTableSet = VariantTableSet.bundled,
                        policy: Policy = Policy.runtime(),
                        correctionPolicy: STTCorrector.Policy? = nil,
                        correctionLexicon: CorrectionLexicon? = CorrectionLexicon.bundled)
        -> IntentTranscriptPair {
        let correctionPolicy = correctionPolicy
            ?? STTCorrector.Policy.runtime(lexicon: correctionLexicon)
        // The corrector runs FIRST and its output is what the canonicalizer
        // reads. While its mode is `.off` (the shipped default: absent
        // preference key, or the compile gate off) `corrected` is the input
        // string itself, so the canonicalizer's input is byte-identical to the
        // expression that ran before this layer existed.
        let correction = STTCorrector.correct(sanitisedTranscript,
                                              lexicon: correctionLexicon,
                                              policy: correctionPolicy)
        let result = DialectCanonicalizer.canonicalize(correction.corrected,
                                                       dialect: dialect,
                                                       tables: tables,
                                                       policy: policy)
        return IntentTranscriptPair(original: sanitisedTranscript,
                                    canonical: result.canonical,
                                    applications: result.applications,
                                    degraded: result.degraded,
                                    tableRevision: result.tableRevision,
                                    notes: result.notes,
                                    correction: correction)
    }

    typealias Policy = DialectCanonicalizer.Policy
}
