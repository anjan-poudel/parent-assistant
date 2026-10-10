/// [MTC] The shared transcript-preparation order (design-l2 L2-D14 / §15,
/// C-MTC-08c): raw capture → sanitisation → the optional input seam → the
/// prepared text.
///
/// ONE implementation, two callers. The brain path
/// (`LocalBrainChain.turnInput`) and the dialogue answer path
/// (`AppCoordinator.prepareDialogueAnswerText`, design-l2 §12.1 edit 8) both
/// prepare a transcript HERE, so the text a local brain reads and the answer
/// value the dialogue interception classifies can never be produced by two
/// different orders.
///
/// The rewire of `LocalBrainChain.turnInput` is behaviour-preserving
/// byte-for-byte: the same order (sanitise, then the seam), the same inputs,
/// the same outputs. `LocalBrainChain.plainText(for:raw:)` is untouched — the
/// brain path keeps its raw-vs-picker equality mapping verbatim — while the
/// dialogue path consumes `Prepared.prepared`, which is the seam's
/// `pickerBrainInput` whenever a seam exists.
///
/// Pure by construction (NFR-MTC-012 log-safety): no caching, no logging, no
/// observability metadata, no clock — there is nothing here that could print
/// a transcript. Deterministic: the same `(raw, seam)` pair yields the same
/// `Prepared`, byte for byte.
enum IntentTranscriptPreparation {

    /// One turn's prepared input, as both callers consume it.
    struct Prepared: Equatable {
        /// The caller's transcript, verbatim — never handed to a model.
        let raw: String
        /// `InputSanitiser.sanitise(raw, level: .quarantine)` when a seam
        /// exists; `raw` itself on a nil seam (the parity branch documented
        /// on `prepare(_:seam:)`).
        let sanitised: String
        /// The dialogue answer path's value: the seam's `pickerBrainInput`
        /// when a seam exists, the raw transcript on a nil seam. Never the
        /// untransformed text once the seam has rewritten something.
        let prepared: String
        /// The STT-corrector + canonicalizer output (`IntentTranscriptPair`),
        /// or nil exactly when the caller owns no seam (the raw pass-through
        /// shape, and every pre-relocation call site).
        let pair: IntentTranscriptPair?
    }

    /// The one order both callers run: sanitise first, then the seam — the
    /// order of the historical `LocalBrainChain.turnInput`.
    ///
    /// - Parameters:
    ///   - transcript: the transcript as the caller received it (`raw`).
    ///   - seam: the local slot's input seam (`LocalBrainChain.InputSeam`),
    ///     or nil for the raw pass-through.
    ///
    ///     **nil-seam raw-passthrough parity (C-5, `review-l2.md`).** A nil
    ///     seam returns the transcript as BOTH `sanitised` and `prepared`,
    ///     unsanitised, byte for byte: the shipped nil-seam path
    ///     `LocalBrainChain.swift:275-285` returns `plainText: transcript`
    ///     untouched, and this branch reproduces that exactly. The sanitiser
    ///     is deliberately not called on this branch.
    ///
    ///     This is test-only parity, NOT a production shape. Note that
    ///     production always wires the seam non-nil — the shipped
    ///     coordinator passes one at `AppCoordinator.swift:1824`, and a
    ///     focused coordinator test re-pins that wiring. (M-3 in
    ///     `security-design-review.md`: no production path may consume an
    ///     unsanitised answer.) With a seam, the answer value derives from
    ///     the sanitiser's output —
    ///     `pair.pickerBrainInput`, whose `original` is exactly
    ///     `InputSanitiser.sanitise(transcript, level: .quarantine)` — so
    ///     the nil-seam branch exists for parity tests only.
    /// - Returns: this turn's `Prepared` value. The seam is run exactly once
    ///   per call (no caching), and a seam that rewrote anything yields its
    ///   `pickerBrainInput` as `prepared`.
    static func prepare(_ transcript: String,
                        seam: LocalBrainChain.InputSeam?) -> Prepared {
        guard let seam else {
            // Parity, not production (see `seam` above): `turnInput` hands
            // the raw transcript through untouched on a chain without a
            // seam, and this branch reproduces that byte for byte. The
            // sanitiser is NOT called here — calling it would break the
            // shipped pass-through.
            return Prepared(raw: transcript,
                            sanitised: transcript,
                            prepared: transcript,
                            pair: nil)
        }
        // The sanitiser is the boundary and comes first (§4.6): the seam is
        // handed sanitised text and nothing else, so a table rewrite can
        // never resurrect text the clamp removed.
        let clean = InputSanitiser.sanitise(transcript, level: .quarantine)
        let pair = seam.prepare(clean)
        return Prepared(raw: transcript,
                        sanitised: clean,
                        prepared: pair.pickerBrainInput,
                        pair: pair)
    }
}
