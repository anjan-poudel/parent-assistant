import Foundation
import Combine

// MARK: - Settings profile editor model (profile-interview, T-103 / C08)
//
// The Settings editor's state holder. It prefills from the store's cached
// snapshot and writes through the coordinator's single profile writer —
// the same merge helpers the wizard uses (`AboutYouDraft` /
// `EmergencyContactsDraft`), so the two callers can never diverge on
// merge semantics. One deliberate difference from the wizard: the editor
// ALLOWS an empty name / address-as — clearing a field is how the user
// returns to the un-personalized path (FR-PI-011); the mandatory-fields
// gate is the wizard's Next contract only.

final class ProfileSettingsModel: ObservableObject {

    enum SaveState: Equatable {
        case idle
        case saved
        case failed
    }

    @Published var name: String = ""
    @Published var addressAs: String = ""
    @Published var hasDateOfBirth: Bool = false
    @Published var dateOfBirth: Date? = nil
    @Published var emergencyDoctor: String = ""
    @Published var localHospital: String = ""
    @Published private(set) var saveState: SaveState = .idle

    /// Entry bounds (grapheme clamps) shared with the wizard — the view
    /// binds through them so a too-long entry never lands in the draft.
    let bounds: ProfileEntryBounds

    private let coordinator: AppCoordinator

    init(coordinator: AppCoordinator, bounds: ProfileEntryBounds = .default) {
        self.coordinator = coordinator
        self.bounds = bounds
    }

    /// Prefill from `coordinator.currentProfileSnapshot()`; empty strings
    /// for absent/cleared fields, toggle off when no DOB is recorded.
    /// Also resets the save state so a fresh screen never shows a stale
    /// "Saved" from a previous visit.
    func load() {
        let base = coordinator.currentProfileSnapshot().mergeBase
        name = base.name
        addressAs = base.addressAs
        if let components = base.dateOfBirth,
           let date = Calendar.current.date(from: components) {
            dateOfBirth = date
            hasDateOfBirth = true
        } else {
            dateOfBirth = nil
            hasDateOfBirth = false
        }
        emergencyDoctor = base.emergencyDoctor ?? ""
        localHospital = base.localHospital ?? ""
        saveState = .idle
    }

    /// Merges via the shared draft semantics and writes the COMPLETE
    /// record through `coordinator.saveProfile`. The base is re-read at
    /// save time, never cached at load time, so the merge always runs
    /// against the freshest stored record — the same behaviour as the
    /// wizard's Next-and-save.
    func save() {
        var aboutDraft = AboutYouDraft()
        aboutDraft.name = name
        aboutDraft.addressAs = addressAs
        aboutDraft.hasDateOfBirth = hasDateOfBirth
        aboutDraft.dateOfBirth = dateOfBirth

        let base = coordinator.currentProfileSnapshot().mergeBase
        let withAbout = aboutDraft.merged(into: base)
        let contactsDraft = EmergencyContactsDraft(emergencyDoctor: emergencyDoctor,
                                                   localHospital: localHospital)
        let merged = contactsDraft.merged(into: withAbout)

        let result = coordinator.saveProfile(
            name: merged.name,
            addressAs: merged.addressAs,
            dateOfBirth: merged.dateOfBirth,
            emergencyDoctor: merged.emergencyDoctor,
            localHospital: merged.localHospital)
        switch result {
        case .success:
            saveState = .saved
        case .failure:
            saveState = .failed
        }
    }
}
