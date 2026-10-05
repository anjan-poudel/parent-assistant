import Foundation
import Combine

/// First-run onboarding progress (spec §4.2).
///
/// Every step is skippable — there is no hard gate anywhere in the wizard.
/// Per-step status (completed/skipped) is persisted so skipped steps can
/// surface as a reminder card on Home.
///
/// [PROFILE-INTERVIEW T-102] The interview steps (`aboutYou`,
/// `emergencyContacts`, `voiceFingerprint`) sit between permissions and
/// the pre-existing family/models steps in `allCases` order — that order
/// is the wizard's walk AND the routing rule's tie-break. The cold-start
/// route (`coldStartInterviewStep`) lives here as a pure function so the
/// coordinator's composition cannot re-implement it differently.
///
/// Main-thread-only by contract (SwiftUI-facing state); not `@MainActor`
/// so it stays constructible from `AppCoordinator`'s nonisolated init.
final class OnboardingState: ObservableObject {

    enum Step: String, CaseIterable, Identifiable {
        case language
        case permissions
        case aboutYou
        case familyContact
        case emergencyContacts
        case voiceFingerprint
        case models

        var id: String { rawValue }

        /// Steps that can be reached as the first incomplete step when the
        /// wizard is reopened from the Home reminder card.
        var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    }

    enum StepStatus: String {
        case completed
        case skipped
    }

    /// Per-step status. Steps absent from the map are still pending.
    @Published private(set) var stepStatuses: [String: String] {
        didSet { persist() }
    }

    /// True once the wizard has been run through to the end (even with
    /// skipped steps). Gates Home vs wizard in `ContentView`.
    @Published private(set) var hasSeenOnboarding: Bool {
        didSet { persist() }
    }

    private static let statusesKey = "onboarding.stepStatuses"
    private static let seenKey = "onboarding.hasSeen"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.stepStatuses = defaults.dictionary(forKey: Self.statusesKey) as? [String: String] ?? [:]
        self.hasSeenOnboarding = defaults.bool(forKey: Self.seenKey)
    }

    // MARK: - Mutations

    func mark(_ step: Step, status: StepStatus) {
        // Full-assignment (not in-place subscript) so the didSet observer
        // fires and persists — in-place mutation bypasses property
        // observers on @Published-wrapped value types.
        var updated = stepStatuses
        updated[step.rawValue] = status.rawValue
        stepStatuses = updated
    }

    func markCompleted(_ step: Step) { mark(step, status: .completed) }
    func markSkipped(_ step: Step) { mark(step, status: .skipped) }

    func status(of step: Step) -> StepStatus? {
        stepStatuses[step.rawValue].flatMap(StepStatus.init(rawValue:))
    }

    /// Wizard was run to the end — swap to Home and remember it.
    func finish() {
        hasSeenOnboarding = true
    }

    /// Steps that were skipped and never completed — feeds the Home
    /// reminder card. Ordered by wizard position.
    var pendingSteps: [Step] {
        Step.allCases.filter { status(of: $0) == nil || status(of: $0) == .skipped }
    }

    /// First incomplete/skipped step — where the wizard reopens from the
    /// Home reminder card.
    var firstPendingStep: Step? { pendingSteps.first }

    // MARK: - Cold-start routing (profile-interview, T-102 / C13)

    /// Where the wizard opens on a cold start (FR-PI-016; design-l2 §7,
    /// edge table):
    ///
    /// - the first pending step, EXCEPT that a missing mandatory record
    ///   (trimmed non-empty name AND address-as in the stored profile)
    ///   routes back to `.aboutYou` whenever About-you is at or before
    ///   the first pending step;
    /// - all steps recorded and the record present → nil (the app starts
    ///   normally);
    /// - all steps recorded but the record missing/unreadable → `.aboutYou`
    ///   (the hard route repairs the record through the wizard's ordinary
    ///   Next-and-save gate — never a crash, never "nothing to do").
    ///
    /// Pure function: the caller supplies the first pending step and the
    /// mandatory-fields predicate result, so the rule is testable without
    /// any storage.
    static func coldStartInterviewStep(firstPending: Step?,
                                       mandatoryFieldsRecorded: Bool) -> Step? {
        guard let first = firstPending else {
            // Nothing pending: the record decides whether there is work.
            return mandatoryFieldsRecorded ? nil : .aboutYou
        }
        guard !mandatoryFieldsRecorded else { return first }
        // Mandatory missing: the earlier of the two in allCases order —
        // never skip past About-you on the way to a later step.
        return first.index < Step.aboutYou.index ? first : .aboutYou
    }

    // MARK: - Persistence

    private func persist() {
        defaults.set(stepStatuses, forKey: Self.statusesKey)
        defaults.set(hasSeenOnboarding, forKey: Self.seenKey)
    }
}
