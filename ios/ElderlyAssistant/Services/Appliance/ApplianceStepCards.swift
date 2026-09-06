import Foundation

/// One step's presentation unit: the numbered instruction text plus the
/// grounded controls whose circles/close-ups belong to it (design §5.2 —
/// the text list and the visual markers stay in sync by step number).
struct ApplianceStepCard: Equatable {
    /// 1-based step number.
    let number: Int
    /// The instruction text for this step.
    let text: String
    /// Controls tied to this step, in original payload order. Empty for a
    /// text-only step (Gemini gave no box, or the box was below the
    /// confidence threshold — the text remains the source of truth).
    let controls: [GroundedControl]
}

/// Groups `steps` + `visibleControls` into ordered cards (the view's only
/// job, so the association rules stay directly unit-testable).
///
/// Association rules, deliberately documented:
///  - A control whose `stepNumber` is 1…steps.count belongs to that step.
///  - A control with a positive but out-of-range stepNumber (Gemini
///    over-counted) is attached to the LAST card — it cannot precede the
///    steps that exist.
///  - A control with no stepNumber at all keeps its old badge position —
///    its index in the payload + 1 — clamped to the last card. This
///    reproduces the numbering the old all-markers overlay showed for
///    such controls, so text and image never drift further apart than
///    they already did.
enum ApplianceStepCardPlanner {

    static func build(steps: [String], controls: [GroundedControl]) -> [ApplianceStepCard] {
        // Without step text there is nothing to anchor a card to; the
        // summary card above still carries the spoken answer.
        guard !steps.isEmpty else { return [] }

        var grouped: [Int: [GroundedControl]] = [:]
        for (index, control) in controls.enumerated() {
            let targetStep: Int
            if let n = control.stepNumber, n >= 1 {
                targetStep = min(n, steps.count)
            } else {
                targetStep = min(index + 1, steps.count)
            }
            grouped[targetStep, default: []].append(control)
        }
        return (1...steps.count).map { stepNumber in
            ApplianceStepCard(number: stepNumber,
                              text: steps[stepNumber - 1],
                              controls: grouped[stepNumber] ?? [])
        }
    }
}
