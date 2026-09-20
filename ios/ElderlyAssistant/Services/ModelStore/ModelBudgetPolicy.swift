import Foundation

// MARK: - [MODEL-WARDEN] Step 3 — the per-class policy
//
// Steps 0–2 made the warden a **runtime** guard: it decides what may become
// resident, and it enforces the decision by eviction. That covers the kill,
// and it leaves a product-shaped hole the proposal names as D1:
//
//   A model that does not fit the class gets in anyway — through
//   `soloOverBudget`, the escape hatch that exists so the household's own
//   chosen brain is never unloadable — and then the STT is evicted on every
//   turn to make room for the pairing the class was never sized for. The
//   household sees a 77 s cold STT load per turn and nothing anywhere says
//   why.
//
// `ModelBudgetPolicy` is that statement made once, per device class: what
// the device is allowed to RUN, expressed in the same vocabulary the ledger
// already uses (`ModelLifecycleBudget.DeviceClass`, the catalog's
// `minDeviceRAMBytes`, `ModelLifecycleInventory`'s derived footprints).
// `availability(of:…)` is the answer the picker needs — a model that cannot
// work here is offered as **unavailable with a reason** rather than admitted
// and then evicted.
//
// It is asked through `ModelLifecycleManager.availability(of:)` (the ledger,
// so the class comes from the probe the admissions use) and it is rendered by
// the Settings screen: the reason sentence on the model row, a short marker on
// the picker option, and no download offered for a model the class cannot
// hold.
//
// [MODEL-WARDEN, 2026-09-18] It also answers what "Automatic" RESOLVES to.
// `LanguageModelResolver.resolvedAutomaticPick` takes the catalogue's language
// default as its first rung, asks this policy the same
// `availability(of:physicalMemoryBytes:warmSTTLiveBytes:)` question a Settings
// row asks, and steps down the ladder — largest artifact that fits beside the
// warm STT — when the class refuses it. So a 6 GB Nepali phone now resolves to
// the 1.7B instead of the 4B that `soloOverBudget` would admit and then evict
// the warm ANE STT on every turn for.
//
// The escape hatch is untouched: an EXPLICITLY stored pick is never overridden
// — the gate is on the automatic path only, and a preference already stored
// keeps today's `soloOverBudget` semantics. (The Step 3 note in
// `ModelLifecycleManager` predates this and still says the policy re-points
// nothing: the resolution lives in the resolver and the ledger's own behaviour
// is unchanged, so read that note as "the ledger does not re-point a load".)
//
// ### What the numbers are
//
// From the proposal's §3.2 table and `specs/model-warden-field-notes.md`
// §2–§3, which are in turn the ledger's own arithmetic (a size bump in the
// catalog moves every figure below with it, because every figure is resolved
// through `ModelLifecycleInventory.footprint(for:modelID:)` — never copied):
//
// | Class    | Budget | Working set (idle) | Warm STT it keeps | Largest brain |
// |----------|--------|--------------------|-------------------|---------------|
// | compact  | 2.0 GB | 0.30 GB            | whisper.cpp small | 1B  (≤ 1.0 GB file) |
// | standard | 3.2 GB | 0.30 GB            | the ANE STT (1.0) | 1.7B (≤ 1.5 GB file) |
// | roomy    | 5.0 GB | 0.40 GB            | the ANE STT (1.0) | 4B  (any) |
//
// ### The two reasons, and why the distinction is the whole point
//
// The proposal's §3.2 carries two consequences that read as surprises, and
// the reason vocabulary is what makes them legible in Settings instead of
// arriving as a latency mystery:
//
//  1. **A 3B on a 6 GB phone cannot keep a warm ANE STT.** 2.82 GB live +
//     1.00 GB STT = 3.82 GB > the 3.2 GB budget. The 3B therefore does not
//     fit *next to* the STT — but it does fit the class alone, which is a
//     different sentence from "this device cannot run it". It is refused as
//     `requiresEvictingWarmSTT`, and the user is told what it would cost.
//  2. **The binding constraint is the STT, not the brain.** The ANE STT's
//     1.00 GB is non-pageable (`hardBytes == liveBytes`) while a brain's
//     0.9 GB is pageable, so the model the latency contract insists stays
//     warm is also the one that must be budgeted most carefully — which is
//     why `requiresWarmSTTCoResidency` is a field and not an assumption
//     buried in a comparison.

/// Why a model cannot be offered on this device class. Closed vocabulary,
/// content-free, one token each — the same rule the ledger's own events
/// follow, so a Settings row and a field capture can name the same fact.
enum ModelUnavailabilityReason: String, Equatable, CaseIterable {
    /// The device does not have the physical RAM the catalog entry declares
    /// (`minDeviceRAMBytes`). The coarsest gate, and the only one that is a
    /// property of the phone rather than of the class.
    case deviceTooSmall = "device_too_small"

    /// The model's own live footprint exceeds the class budget, so no
    /// eviction could make room for it. This is the `soloOverBudget`
    /// condition seen from the picker's side: it is admitted today as an
    /// escape hatch for a preference already stored, but it is not a model
    /// the class can hold, and offering it as a normal choice is how a
    /// household ends up in the evict-the-STT loop.
    case overClassBudget = "over_class_budget"

    /// The model **fits the class but not the working set**: it is under the
    /// budget alone, and over it as soon as the STT the voice turn needs
    /// warm is counted beside it. This is the 3B-on-6 GB case, and the
    /// reason exists precisely so that refusal is not silent — the model is
    /// real, the phone can hold it, and choosing it costs a cold STT load
    /// per turn.
    case requiresEvictingWarmSTT = "requires_evicting_warm_stt"

    /// The class's stated largest brain is smaller than the arithmetic would
    /// allow. A **product** refusal rather than a memory one — the ladder in
    /// §7 Q1 — which is why it is a separate word: it is the case where a
    /// later catalog entry could fit and still should not be offered.
    case overBrainCeiling = "over_brain_ceiling"

    /// The `Localizable.xcstrings` key for the sentence a Settings row shows.
    ///
    /// The token above is for the observability bus and the key is for the
    /// screen; both are closed, constant, and content-free — which is what
    /// lets a field capture and a Settings row name the same fact without
    /// either of them carrying an artifact.
    var localizationKey: String {
        switch self {
        case .deviceTooSmall: return "model.unavailable.deviceTooSmall"
        case .overClassBudget: return "model.unavailable.overClassBudget"
        case .requiresEvictingWarmSTT:
            return "model.unavailable.requiresEvictingWarmSTT"
        case .overBrainCeiling: return "model.unavailable.overBrainCeiling"
        }
    }
}

/// Whether a catalog entry may be chosen on this device, and if not, the
/// sentence that says why.
enum ModelAvailability: Equatable {
    case available
    case unavailable(reason: ModelUnavailabilityReason)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var reason: ModelUnavailabilityReason? {
        guard case .unavailable(let reason) = self else { return nil }
        return reason
    }
}

/// The per-device-class policy. See the file header for the table.
///
/// Every field is a *default on a configurable surface*, in the same sense
/// `ModelWardenConfig`'s bounds are: the owner's four open decisions (§7)
/// are settled as values here, where revising one is a one-line change and
/// not a rewrite of a comparison buried in the ledger.
struct ModelBudgetPolicy: Sendable, Equatable {

    let deviceClass: ModelLifecycleBudget.DeviceClass

    /// The app's own working set when nothing heavy is on screen — the
    /// "~300 MB" of `docs/architecture/model-lifecycle.md`. Carried
    /// explicitly because the budget's derivation is
    /// `ceiling − workingSet`, and a class whose real `W(t)` has grown (the
    /// cost model's `footprintSample` stream is what measures it) is a class
    /// whose budget premise has moved.
    let workingSetIdleBytes: UInt64

    /// The measured live footprint of a camera session —
    /// **1.18–1.41 GB**, `LiveTranslateConfig.swift:383`. This is the field
    /// that makes §3.3 expressible at all: with the camera live, `W(t)`
    /// swings by more than the gap between the 1.7B and the 4B brains, so a
    /// session that also wants a brain has to spend budget it does not have.
    ///
    /// **Wired** ([CAMERA-BUDGET], 2026-09-20): `LiveCameraSession` reports
    /// activation through `onSessionActiveChanged`, the coordinator hands
    /// that to `ModelLifecycleManager.setSessionProfile(_:owner:)`, and
    /// `sessionModelBudgetBytes(session:)` — which this field feeds — is what
    /// the warden computes the lowered budget with. The field is what makes
    /// the camera session's own footprint part of `W(t)` rather than
    /// something the ledger hopes has already been subtracted.
    let workingSetCameraBytes: UInt64

    /// The artifact ceiling of the largest brain the class may be offered.
    /// Compared against the **file** size (the quantity the user and the
    /// catalog both think in), which is also what `brainClasses` keys on —
    /// so a class's ladder is stated in the same units as the ledger's
    /// overhead table.
    let largestAllowedBrainFileBytes: UInt64

    /// What the class is expected to keep warm beside a brain. Resolved from
    /// the inventory, not written down: the ANE STT on the classes that ship
    /// it (`standard`, `roomy`), the cheap whisper.cpp context on `compact`
    /// (whose row in §3.2 pairs the 1B with a small q5 precisely because a
    /// 4 GB device cannot hold the 1.0 GB ANE graph beside a brain).
    let warmSTTReserveBytes: UInt64

    /// Whether the class's brain ladder is a *co-residency* rule — i.e.
    /// whether a brain that forces the STT out is refused rather than
    /// offered. True for every class in the shipped table (the proposal's
    /// §3.2 recommendation), and a field rather than a constant because it
    /// is the owner's decision §7 Q1 and the one that costs latency.
    let requiresWarmSTTCoResidency: Bool

    /// The most a single load may reserve on this class. Equal to the class
    /// budget: a reservation larger than that is only reachable through the
    /// `soloOverBudget` escape hatch, which is a *stored preference* safety
    /// valve and not a path the picker opens.
    let maxTransientReserveBytes: UInt64

    /// The class's load-rate default, in large loads per rolling minute.
    /// Held equal to `ModelWardenConfig.default.maxLoadsPerMinute` by a test
    /// rather than by an initializer, so Step 2's guard keeps its own
    /// defaults and the two cannot drift apart unnoticed.
    let maxLoadsPerMinute: Int

    // MARK: The shipped table

    /// Under 5 GB physical — the 4 GB iPhone tier. The class where the ANE
    /// STT and *any* shipped brain cannot co-reside at all — see the finding
    /// in the Step 3 report.
    static let compact = ModelBudgetPolicy(
        deviceClass: .compact,
        workingSetIdleBytes: 300 * 1_000_000,
        workingSetCameraBytes: 1_400_000_000,
        largestAllowedBrainFileBytes: 1_000_000_000,   // brainClasses 1B
        warmSTTReserveBytes: 650 * 1_000_000,          // whisper.cpp small q5
        requiresWarmSTTCoResidency: true,
        maxTransientReserveBytes: ModelLifecycleBudget.compactModelsBudgetBytes,
        maxLoadsPerMinute: 4)

    /// 5–7 GB physical — the 6 GB iPhone tier, the class the whole mechanism
    /// exists for, and the one §3.2 says must not be offered a 3B.
    static let standard = ModelBudgetPolicy(
        deviceClass: .standard,
        workingSetIdleBytes: 300 * 1_000_000,
        workingSetCameraBytes: 1_400_000_000,
        largestAllowedBrainFileBytes: 1_500_000_000,   // brainClasses 1.7B
        warmSTTReserveBytes: 1_000_000_000,            // the ANE STT
        requiresWarmSTTCoResidency: true,
        maxTransientReserveBytes: ModelLifecycleBudget.standardModelsBudgetBytes,
        maxLoadsPerMinute: 4)

    /// ≥ 7 GB physical. The 3B's home (§7 Q1), and the only class where the
    /// 4B co-resides with a warm ANE STT.
    static let roomy = ModelBudgetPolicy(
        deviceClass: .roomy,
        workingSetIdleBytes: 400 * 1_000_000,
        workingSetCameraBytes: 1_400_000_000,
        largestAllowedBrainFileBytes: .max,            // brainClasses 4B
        warmSTTReserveBytes: 1_000_000_000,            // the ANE STT
        requiresWarmSTTCoResidency: true,
        maxTransientReserveBytes: ModelLifecycleBudget.roomyModelsBudgetBytes,
        maxLoadsPerMinute: 4)

    static func policy(for deviceClass: ModelLifecycleBudget.DeviceClass)
    -> ModelBudgetPolicy {
        switch deviceClass {
        case .compact: return .compact
        case .standard: return .standard
        case .roomy: return .roomy
        }
    }

    /// The policy for the device the app is running on.
    static func policy(forPhysicalMemoryBytes bytes: UInt64) -> ModelBudgetPolicy {
        policy(for: ModelLifecycleBudget.deviceClass(physicalMemoryBytes: bytes))
    }

    // MARK: The class budget, from the policy's own numbers

    /// The model budget in force for a session profile.
    ///
    ///     budget(session) = classBudget − (W(session) − W(idle))
    ///
    /// At `.idle` this is **exactly** `modelsBudgetBytes(for:)` — the number
    /// the ledger already admits against — and that identity is asserted by
    /// `ModelBudgetPolicyTests`, because two spellings of one number is
    /// precisely the drift this type exists to prevent. Every class budget
    /// in the tree was derived with some working set subtracted from the
    /// ceiling the class is planned against, so the field that says *which*
    /// working set is what makes the session case derivable rather than
    /// invented: a session whose `W(t)` is larger by 1.1 GB has a model
    /// budget smaller by the same 1.1 GB, and §3.3's "the camera session
    /// changes the budget, not just the model" is that sentence.
    ///
    /// Saturating at zero, so a class can never be driven negative by a
    /// session profile it was never sized for.
    func sessionModelBudgetBytes(session: SessionProfile) -> UInt64 {
        let full = ModelLifecycleBudget.modelsBudgetBytes(for: deviceClass)
        let idle = workingSetIdleBytes
        let sessionWorkingSet = session.workingSetBytes(idle: idle,
                                                        camera: workingSetCameraBytes)
        guard sessionWorkingSet > idle else { return full }
        let growth = sessionWorkingSet - idle
        return growth >= full ? 0 : full - growth
    }

    /// Which working set the app is in. Named for the two the proposal's
    /// numbers exist for; it is deliberately not a general "session kind"
    /// enum, because a session with no measurement behind it would be a
    /// budget nobody could defend.
    enum SessionProfile: String, Equatable, CaseIterable {
        /// Nothing heavy on screen: models plus ~300 MB of app.
        case idle
        /// A camera translation session: the measured 1.18–1.41 GB Vision +
        /// capture footprint.
        case cameraLive

        func workingSetBytes(idle: UInt64, camera: UInt64) -> UInt64 {
            switch self {
            case .idle: return idle
            case .cameraLive: return camera
            }
        }
    }

    // MARK: Availability

    /// Whether `entry` may be **chosen** on this policy's device class.
    ///
    /// Only brain-shaped entries are gated. The light residents (voices, the
    /// wake-word spotter, the VAD, the encoder) are 0.14 GB or less, they
    /// co-reside by design, and the catalog's own `minDeviceRAMBytes` is the
    /// only bound any of them has ever needed — inventing a class rule for
    /// them would refuse choices that work, which is the failure mode this
    /// whole gate exists to avoid.
    ///
    /// `warmSTTLiveBytes` is the footprint of the STT the class keeps warm,
    /// resolved by the caller through
    /// `ModelLifecycleInventory.footprint(for: .speechToText, modelID:)` so
    /// a catalog size bump moves it. `nil` falls back to the policy's own
    /// reserve, which is what a caller with no selection to hand (a
    /// Settings list rendered before any model is chosen) has.
    ///
    /// **Floors below the compact boundary** (`ModelCatalog`). A floor is
    /// about the PHONE — `minDeviceRAMBytes` against physical RAM — while
    /// this policy is about the CLASS, so a sub-boundary floor deliberately
    /// admits a `.compact` device and this function is what refuses it. The
    /// reconciliation, so the two are not read as disagreeing:
    ///
    ///  · Harmless exactly when the refusal is *shown*. A brain card hides
    ///    its Download on a refusal (`ModelManagementRow`), so the household
    ///    reads the sentence instead of spending the data; the entry is
    ///    still deletable. It is harmful on the translation card, which
    ///    offers its download while unavailable
    ///    (`downloadsWhileUnavailable: true`) — which is why the two shipped
    ///    translation floors sit ON the boundary
    ///    (`ModelLifecycleBudget.compactBoundaryBytes`) rather than inside
    ///    it, and why `ModelDownloadService` now consults this policy before
    ///    it starts.
    ///  · A sub-boundary brain floor that compact genuinely *can* hold
    ///    (`llama3_2_1B`, `intentGemma1B`: ~1.3 GB live, inside the 2 GB
    ///    compact budget) is correct as it stands; both are hidden rungs.
    ///  · Non-brain kinds (STT, TTS, VAD, KWS, the encoder) are exempt by
    ///    construction: for them this function returns right after the
    ///    device check above, so their floor is the only bound there is and
    ///    the class line has nothing to do with it.
    func availability(of entry: ModelCatalogEntry,
                      physicalMemoryBytes: UInt64,
                      warmSTTLiveBytes: UInt64? = nil,
                      budgetBytes: UInt64? = nil) -> ModelAvailability {
        guard entry.kind == .llamaBase || entry.kind == .llamaLoRA else {
            // Not a brain: the class policy has nothing to say about it.
            return entry.minDeviceRAMBytes > physicalMemoryBytes
                ? .unavailable(reason: .deviceTooSmall)
                : .available
        }
        guard entry.minDeviceRAMBytes <= physicalMemoryBytes else {
            return .unavailable(reason: .deviceTooSmall)
        }

        let footprint = ModelLifecycleInventory.footprint(for: .brain,
                                                          modelID: entry.id)
        let budget = budgetBytes ?? ModelLifecycleBudget.modelsBudgetBytes(for: deviceClass)
        let warmSTT = warmSTTLiveBytes ?? warmSTTReserveBytes

        // The ladder is the *statement*; the two arithmetic conditions are
        // the *sentences* that explain it. A model over the ladder is
        // refused whichever of the two it is, and the reason reported is the
        // more specific one the numbers actually support — so a household
        // reading "it would evict the STT every turn" is reading a fact
        // about this model on this phone, not a restatement of the table.
        let overLadder = footprint.weightsBytes > largestAllowedBrainFileBytes
        let overBudgetAlone = footprint.liveBytes > budget
        let overBudgetWithSTT = requiresWarmSTTCoResidency
            && footprint.liveBytes + warmSTT > budget

        if overBudgetAlone { return .unavailable(reason: .overClassBudget) }
        if overBudgetWithSTT {
            return .unavailable(reason: .requiresEvictingWarmSTT)
        }
        if overLadder { return .unavailable(reason: .overBrainCeiling) }
        return .available
    }

    /// The warm-STT footprint this policy's class plans against, resolved
    /// from the inventory so a catalog size bump moves it. `nil` means the
    /// caller has no selection to hand and the policy's own reserve stands.
    static func warmSTTLiveBytes(forSTTModelID modelID: ModelID?) -> UInt64? {
        guard let modelID else { return nil }
        return ModelLifecycleInventory.footprint(for: .speechToText,
                                                 modelID: modelID).liveBytes
    }

    /// The sentence's **English fallback**, for a caller whose string table
    /// has no entry for `reason.localizationKey` (and for the tests, which
    /// pin it content-free). The shipped sentence is the `xcstrings` value;
    /// this is what a language the table has no row for falls back to.
    ///
    /// Content-free by construction, like the token: it names a memory fact
    /// about the *phone*, never an artifact — no filename, no size, no model
    /// id. On the class-specific case the sentence's job is to say what the
    /// refusal would COST ("every reply would start with a long wait") rather
    /// than to restate the table, which is why it does not need the class as
    /// an argument: the cost is the same on every class that refuses it.
    static func displayText(for reason: ModelUnavailabilityReason) -> String {
        switch reason {
        case .deviceTooSmall:
            return "This phone does not have enough memory to run it."
        case .overClassBudget:
            return "This phone cannot hold this model at all."
        case .requiresEvictingWarmSTT:
            return "This phone cannot run this model and keep voice "
                + "recognition ready at the same time. Choosing it would "
                + "make every reply start with a long wait."
        case .overBrainCeiling:
            return "This phone's voice setup is not sized for this model. "
                + "Pick the recommended one."
        }
    }
}

// MARK: - The picker's own gate

extension ModelBudgetPolicy {

    /// The availability of every entry in `entries`, keyed by id — the shape
    /// a Settings list wants.
    ///
    /// Availability is a property of the *device class*, not of a
    /// preference, so the answer does not depend on what is currently
    /// selected; `warmSTTLiveBytes` only decides which sentence a refusal
    /// gets. That matters for the picker: a row whose model is unavailable
    /// must look the same before and after the household switches language.
    func availability(in entries: [ModelCatalogEntry],
                      physicalMemoryBytes: UInt64,
                      warmSTTModelID: ModelID? = nil,
                      budgetBytes: UInt64? = nil) -> [ModelID: ModelAvailability] {
        let warm = Self.warmSTTLiveBytes(forSTTModelID: warmSTTModelID)
        var result: [ModelID: ModelAvailability] = [:]
        for entry in entries {
            result[entry.id] = availability(of: entry,
                                            physicalMemoryBytes: physicalMemoryBytes,
                                            warmSTTLiveBytes: warm,
                                            budgetBytes: budgetBytes)
        }
        return result
    }
}
