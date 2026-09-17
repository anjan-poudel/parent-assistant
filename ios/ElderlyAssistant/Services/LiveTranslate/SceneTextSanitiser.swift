import Foundation

// C07 — `SceneTextSanitiser` (T-017).
//
// Recognized scene text is **attacker-influenceable input**. Anyone can print
// a sign, a label or a menu whose text is shaped like a directive aimed at a
// language model, and the live camera path hands whatever the camera sees to
// tier 2. This file is the boundary that stands between the two.
//
// What it exists to make true:
//
//  - **A verdict, never a bare string.** `sanitiseForEgress(_:maxLength:)`
//    returns `.sendable` / `.truncated` / `.quarantined`, and the quarantined
//    case carries a *reason* and no text at all. A caller therefore has
//    nothing to send and nothing to speak for a quarantined string: the
//    exclusion is a property of the type, not a rule someone has to remember.
//  - **Strip, then detect, then quarantine.** The stripping half is the
//    project's configured quarantine level (`InputSanitiser.sanitise`), and
//    the detection half is the same table's detect-only seam
//    (`InputSanitiser.containsInjectionMarker`). The order matters: the
//    removal walk goes over the table once, so a removal can *reconstitute* a
//    shape that was split by another one (pinned by T-004's residual test).
//    A raw input is therefore stripped first and the **residual** is what
//    quarantines — inverting the order would quarantine strings the shared
//    sanitiser already made safe and would let a reconstituted shape through.
//  - **One table, no copy (AM-3, CL-6).** The marker table is private to
//    `InputSanitiser` and this file references the accessors by name only. A
//    source-level test fails if a marker family is restated anywhere under
//    `Services/LiveTranslate/`, so this path's policy cannot drift away from
//    the project's configured quarantine level.
//  - **Total, with no error path (failure table row 21).** Every input string
//    — empty, whitespace, over-long, marker-shaped — returns exactly one
//    verdict. Quarantine is a verdict, not a thrown failure, because the
//    caller must render the region either way (the elder's own camera saw
//    the text; it is shown as it is with a neutral note and never sent and
//    never spoken — FR-LCT-014).
//  - **Truncation is not quarantine (FR-LCT-016).** Over-long text is cut to
//    the configured bound with `String.prefix(_:)`, which counts **extended
//    grapheme clusters**, so a Devanagari conjunct or cluster cannot be split
//    in half. Truncated text is still sent.
//  - **Bounding is per string and per batch.** `bound(_:maxStrings:
//    maxCharacters:)` splits an over-large set into sequential batches rather
//    than dropping strings; a single string larger than the character bound
//    is kept in a batch of its own (the pipeline truncates per string first,
//    so that branch is unreachable through the live path — it exists so the
//    function stays total rather than silently discarding input).
//
// The bounds are parameters, not constants: `LiveTranslateConfig` owns every
// operational value (NFR-LCT-011), and a literal here would be caught by the
// source-hygiene scan.

/// C07 — sanitisation and bounding of recognized scene text before egress.
///
/// Pure and total. No I/O, no state, no clock: every function is a decision
/// about strings, which is what makes the whole verdict table unit-testable
/// directly.
enum SceneTextSanitiser {

    // MARK: - Verdict

    /// What sanitisation decided about one recognized string.
    ///
    /// `.quarantined` deliberately carries **no text**. The offending string
    /// is still on the elder's screen (their camera saw it) and the overlay
    /// reads it from the region it already owns — it is never handed onward
    /// by this type, so it cannot be sent, embedded in a prompt, spoken or
    /// logged by anything downstream of a verdict.
    enum Verdict: Equatable {
        /// The sanitised text may enter a request payload.
        case sendable(String)
        /// The text exceeded the bound and was cut to it, on a grapheme
        /// boundary. Still sent: truncation is not a quarantine.
        case truncated(String)
        /// The text still matched the shipped marker table after
        /// sanitisation. Not sent, not spoken, shown as-is with a neutral
        /// note.
        case quarantined(QuarantineReason)

        /// The text that may travel, or nil when nothing may.
        var payload: String? {
            switch self {
            case .sendable(let text), .truncated(let text): return text
            case .quarantined: return nil
            }
        }

        /// Whether this verdict excludes the string from egress.
        var isQuarantined: Bool {
            if case .quarantined = self { return true }
            return false
        }

        /// Whether the bound was applied (and the text is still sent).
        var wasTruncated: Bool {
            if case .truncated = self { return true }
            return false
        }

        /// Why the string was quarantined, or nil for the two egress
        /// verdicts.
        var quarantineReason: QuarantineReason? {
            guard case .quarantined(let reason) = self else { return nil }
            return reason
        }
    }

    // MARK: - One string

    /// The verdict for one recognized string.
    ///
    /// The three steps are the design's order and are not interchangeable:
    /// strip (the shared, configured removal), detect a **residual** on the
    /// stripped text (the shared detect-only seam), then decide. `maxLength`
    /// is the per-string bound from `LiveTranslateConfig.sceneTextMaxLength`.
    static func sanitiseForEgress(_ raw: String, maxLength: Int) -> Verdict {
        // 1. Strip. The project's quarantine level, exactly as the transcript
        //    path applies it — same table, same removal semantics.
        let stripped = InputSanitiser.sanitise(raw, level: .quarantine)

        // 2. Detect what stripping left behind. A residual match is the
        //    quarantine trigger; the seam is the authority and no list is
        //    reproduced here (AM-3, CL-6).
        if InputSanitiser.containsInjectionMarker(stripped) {
            return .quarantined(.markerResidual)
        }

        // 3. Nothing usable survived (only control characters, only
        //    whitespace, or only markers): there is no text to translate.
        //    Still a verdict, still shown as the original with the neutral
        //    note.
        guard !stripped.isEmpty else { return .quarantined(.emptyAfterSanitise) }

        // 4. Bound on extended grapheme clusters. `prefix` never splits a
        //    Devanagari cluster or conjunct, which is the regression the
        //    project has already pinned once for Nepali substring handling.
        guard stripped.count > maxLength else { return .sendable(stripped) }
        return .truncated(String(stripped.prefix(maxLength)))
    }

    // MARK: - A batch of strings

    /// One recognized string on its way to egress, with the region id it
    /// belongs to. The id is opaque to this type; it exists so a caller can
    /// map a verdict back to the region that produced it.
    struct Item: Equatable {
        let id: String
        let text: String
    }

    /// A quarantined region: which one, and why. There is deliberately no
    /// text field — the thing that must not travel has nowhere to travel in.
    struct Quarantined: Equatable {
        let id: String
        let reason: QuarantineReason
    }

    /// The verdicts for a whole batch.
    ///
    /// `sendable` holds the sanitised (possibly truncated) texts in input
    /// order; `quarantined` names the regions that must degrade with the
    /// neutral note, and says why.
    struct BatchVerdict: Equatable {
        let sendable: [Item]
        let quarantined: [Quarantined]

        var quarantinedIDs: [String] { quarantined.map(\.id) }
        var quarantinedCount: Int { quarantined.count }
        var isEmpty: Bool { sendable.isEmpty && quarantined.isEmpty }
    }

    /// The verdict for every string in a batch.
    static func sanitiseBatch(_ items: [Item], maxLength: Int) -> BatchVerdict {
        var sendable: [Item] = []
        var quarantined: [Quarantined] = []
        for item in items {
            switch sanitiseForEgress(item.text, maxLength: maxLength) {
            case .sendable(let text), .truncated(let text):
                sendable.append(Item(id: item.id, text: text))
            case .quarantined(let reason):
                quarantined.append(Quarantined(id: item.id, reason: reason))
            }
        }
        return BatchVerdict(sendable: sendable, quarantined: quarantined)
    }

    /// Records the quarantine as a **count and nothing else** (T-003). The
    /// verdict holds no text, so the record cannot carry one; this is the one
    /// place the scene-text path reports a quarantine.
    static func record(_ verdict: BatchVerdict, on events: LiveTranslateEvents) {
        guard verdict.quarantinedCount > 0 else { return }
        events.textQuarantined(count: verdict.quarantinedCount)
    }

    // MARK: - Bounding

    /// Splits `items` into sequential batches that respect both bounds.
    ///
    /// Greedy and order-preserving: a batch is closed when adding the next
    /// string would exceed `maxStrings` or `maxCharacters`, and a fresh batch
    /// is started. Nothing is dropped — a string larger than
    /// `maxCharacters` on its own keeps a batch to itself rather than
    /// disappearing, because silently dropping a recognized string is the
    /// failure this function exists to prevent.
    ///
    /// An empty input yields no batches, which is the honest encoding of
    /// "there is nothing to request" (and what keeps an empty scene from
    /// producing an empty request).
    static func bound(_ items: [String], maxStrings: Int, maxCharacters: Int) -> [[String]] {
        var batches: [[String]] = []
        var current: [String] = []
        var currentCharacters = 0

        for item in items {
            let exceedsCount = current.count >= maxStrings
            let exceedsCharacters = !current.isEmpty
                && currentCharacters + item.count > maxCharacters
            if !current.isEmpty, exceedsCount || exceedsCharacters {
                batches.append(current)
                current = []
                currentCharacters = 0
            }
            current.append(item)
            currentCharacters += item.count
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }
}
