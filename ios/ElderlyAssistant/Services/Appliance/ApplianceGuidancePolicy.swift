import Foundation

/// Presentation decisions for appliance guidance (design §4.1 — concrete
/// thresholds, not "some threshold"). Everything user-facing about
/// confidence lives here so the view stays a dumb renderer and the rules
/// stay directly unit-testable.
///
/// The two thresholds are deliberately asymmetric:
///  - **Identification < 0.4** → still present the answer, but explicitly
///    hedged. There is no keyword fallback for "what is this appliance" —
///    a disclosed best-effort answer beats refusing (§4.1).
///  - **Per-control < 0.5** → drop that control's circle entirely; its
///    step text still shows. A wrong circle actively misleads an elderly
///    user in a way a missing circle does not (§4.1).
enum ApplianceGuidancePolicy {

    /// Below this, the whole identification is presented as an explicit
    /// guess ("पक्का छैन, तर…"), never silently as fact.
    static let identificationConfidenceThreshold = 0.4
    /// Below this, a control's overlay circle is never drawn.
    static let controlConfidenceThreshold = 0.5

    /// What the view renders, pre-decided.
    struct Presentation: Equatable {
        let guidance: ApplianceGuidance
        /// Identification confidence < 0.4 → hedge the answer aloud and
        /// on screen.
        let hedged: Bool
        /// Controls whose circle may be drawn: confidence ≥ 0.5 AND a
        /// geometrically sane box (malformed boxes dropped too — a
        /// nonsense circle is as misleading as a wrong one).
        let visibleControls: [GroundedControl]
        /// True when there is step guidance but NOTHING could be circled —
        /// the "can't locate precisely" fallback (§7): text-only guidance
        /// plus asking for a closer/different photo.
        let showCloserPhotoHint: Bool
    }

    static func presentation(for guidance: ApplianceGuidance) -> Presentation {
        let visible = guidance.groundedControls.filter {
            $0.confidence >= controlConfidenceThreshold && $0.normalizedBox.isValid
        }
        return Presentation(
            guidance: guidance,
            hedged: guidance.confidence < identificationConfidenceThreshold,
            visibleControls: visible,
            showCloserPhotoHint: visible.isEmpty && !guidance.steps.isEmpty
        )
    }
}
