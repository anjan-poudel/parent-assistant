import Foundation

// MARK: - The probe seam

/// The memory readings the lifecycle manager gates on.
///
/// `MemoryProbe` is an `enum` of static properties with no injection seam, so
/// the manager takes this protocol instead and production passes
/// `SystemMemoryProbe` — the same "injected closure/provider for a system
/// call" convention as `ModelStore.entryProvider` and
/// `ModelDownloadService.availableBytesProvider`. Tests inject a scripted
/// probe and drive the budget arithmetic deterministically.
protocol MemoryProbing {
    /// Total device RAM. Constant per device.
    var physicalMemoryBytes: UInt64 { get }
    /// The app's *current* headroom under its jetsam ceiling, i.e.
    /// `ceiling − footprint`. Re-read at every load.
    var availableProcessMemoryBytes: UInt64 { get }
    /// The app's own resident footprint (`phys_footprint`). [MODEL-WARDEN]
    /// Step 0 telemetry: this is the reading that makes the ledger's
    /// inferred total checkable against the kernel's own number.
    var physFootprintBytes: UInt64 { get }
}

extension MemoryProbing {
    /// Default for the scripted doubles: a probe that does not model a
    /// footprint reports 0, which is the honest "not measured" value. It is
    /// deliberately NOT a derived estimate — a fake that silently invented
    /// `ceiling − available` would pass tests that a real failed probe
    /// could not, and `MemoryProbe` documents zero as the failure value for
    /// the same reason.
    var physFootprintBytes: UInt64 { 0 }
}

/// Production probe: a pass-through to `MemoryProbe`.
struct SystemMemoryProbe: MemoryProbing {
    var physicalMemoryBytes: UInt64 { MemoryProbe.physicalMemoryBytes }
    var availableProcessMemoryBytes: UInt64 {
        MemoryProbe.availableProcessMemoryBytes
    }
    var physFootprintBytes: UInt64 { MemoryProbe.physFootprintBytes }
}

// MARK: - Outcomes

enum LoadDenialReason: String, Equatable {
    /// The model's non-pageable bytes alone exceed the app's remaining
    /// headroom. Loading it would go over the ceiling no matter what we
    /// evict first — this is the one case where the honest answer is "no".
    case insufficientHeadroom
    /// The slot was never registered, so the manager has no release path
    /// for it and must not admit residency it cannot undo.
    case unregisteredSlot
    /// The model would fit on its own, but every remaining resident is
    /// unevictable right now (pinned by an in-flight inference). Loading
    /// would cross the budget, so the answer is no — retry after the
    /// in-flight work settles.
    case budgetExhausted
}

enum LoadAdmission: Equatable {
    case allowed(evicted: [ModelSlot])
    case denied(LoadDenialReason)

    var isAllowed: Bool { if case .allowed = self { return true }; return false }
}

enum EvictionReason: String, Equatable {
    /// A load needed the room (pre-load budget check).
    case budget
    /// UIKit level-2 memory warning.
    case memoryPressure
    /// A `.critical` kernel memory-pressure event: the app is being asked to
    /// give back everything it can, not just to squeeze. [MODEL-WARDEN]
    case criticalPressure
    /// Unused past the idle threshold.
    case idle
    /// Caller asked (model swap, explicit teardown).
    case explicit
    /// [MODEL-WARDEN] Step 2 — the bytes were taken after the owner was
    /// *asked* and either agreed or was overruled by the release contract
    /// (`PreemptionOutcome.forced`). Distinct from `.budget` on purpose:
    /// `.budget` is the ledger taking an idle resident's bytes, `.preemption`
    /// is a conversation, and only the second one costs a feature a handle
    /// it was actively holding.
    case preemption
}

/// [MODEL-WARDEN] Step 0 — the kernel's memory-pressure levels, as reported
/// by `DispatchSource.makeMemoryPressureSource`.
///
/// The tree observed `.warning` (UIKit level 1) and `.critical` (level 2) as
/// a *notification* before Step 0; the dispatch source is the closer-to-the-
/// kernel signal, arriving before the notification and with the level
/// attached rather than inferred.
enum MemoryPressureLevel: String, Equatable {
    /// Plenty of room; sent once when a source is first activated.
    case normal
    /// The OS would like memory back. Same response as a level-1 warning.
    case warning
    /// The OS is about to act. Evict everything evictable, including the
    /// light models the warning path spares, and cancel every load that has
    /// not committed yet — a load in flight is a *future* spike, and this is
    /// the one moment the app can still decline to create it.
    case critical
}

/// [PRESSURE-SAFE LOAD] (2026-09-19) The kernel's memory-pressure state, as
/// this manager last observed it — the reading a *load gate* is built on.
///
/// The level alone answers "what did the kernel last say", which is not quite
/// the question a load has to ask: a `.critical` that fired three seconds ago
/// on a device that has been quiet since is indistinguishable from one that
/// fired an hour ago, because the next dispatch event may not arrive for
/// minutes while the device's jetsam accounting is still catching up. The age
/// is the second half of the fact, so the two travel together and the
/// **caller's own** recency window decides what to do with them.
///
/// Deliberately raw facts and no policy. The window is a feature's number
/// (`LiveTranslateConfig.brainTranslationCriticalPressureWindowSeconds`) and
/// this type has no opinion about it — which is what lets one ledger serve a
/// tier that must be cautious and a prefetch that need not be.
struct MemoryPressureReading: Equatable {
    /// The most recent level the kernel reported — `.normal` until a source
    /// has been installed or a level routed by hand.
    let level: MemoryPressureLevel
    /// How long ago `.critical` last fired, measured against the manager's own
    /// clock. `nil` when it never has, which is not the same as "long ago":
    /// a device that has never been critical is one this rule has nothing to
    /// say about, and reporting `0` there would make every device look
    /// momentarily critical.
    let secondsSinceCritical: TimeInterval?
    /// [PRESSURE-LATCH] (2026-09-19) How long ago `.warning` last fired, on
    /// the same clock and with the same `nil` meaning as the critical age.
    ///
    /// It is here because a `.warning` is the one level that can arrive on a
    /// route with no counterpart: the dispatch source sends `.normal` when the
    /// pressure eases (which is what clears the level), while the UIKit route
    /// records `.warning` and nothing in the app ever takes it back. A caller
    /// that refuses a load on the bare level therefore refuses it for the rest
    /// of the process's life after one transient warning. The age is the
    /// caller's escape hatch, and the window it compares against is the
    /// caller's own number for the same reason `secondsSinceCritical`'s is:
    /// this type carries raw facts and no policy.
    ///
    /// Optional with a default rather than required, so every reading a test
    /// or a caller built before this key existed keeps its meaning — and a
    /// reading that carries no age is treated as *fresh* by the one caller
    /// that reads it, which is the conservative half.
    let secondsSinceWarning: TimeInterval?

    init(level: MemoryPressureLevel,
         secondsSinceCritical: TimeInterval?,
         secondsSinceWarning: TimeInterval? = nil) {
        self.level = level
        self.secondsSinceCritical = secondsSinceCritical
        self.secondsSinceWarning = secondsSinceWarning
    }

    /// What a manager reports before any signal has arrived: the kernel has
    /// not said anything, so nothing is forbidden.
    static let unknown = MemoryPressureReading(level: .normal, secondsSinceCritical: nil)
}

/// [CAMERA-BUDGET] Why a session profile's lease changed. Closed tokens, one
/// word each — the same rule every other lifecycle event follows, so a capture
/// can count profiles without parsing a sentence.
enum SessionProfileEventReason: String, Equatable {
    /// A session's profile took effect (or was refreshed by the same owner).
    case applied
    /// The owner that set it cleared it — the ordinary end of a session.
    case cleared
    /// The lease outlived `ModelWardenConfig.sessionProfileTTLSeconds`.
    case expired
    /// The owner was deallocated without clearing: the leak the owner token
    /// exists to stop.
    case ownerReleased
    /// A `clear` arrived from something that is not the owner that set the
    /// profile — a stale session's late `false`. Refused, and reported.
    case refusedStaleOwner
}

/// Everything the manager did, in order. The coordinator can bridge these to
/// the observability bus; tests assert on them directly.
enum ModelLifecycleEvent: Equatable {
    case admitted(slot: ModelSlot, liveBytes: UInt64, evicted: [ModelSlot])
    case denied(slot: ModelSlot, reason: LoadDenialReason)
    case evicted(slot: ModelSlot, reason: EvictionReason)
    /// [CAMERA-BUDGET] (review finding on #99, 2026-09-20) The session
    /// profile the budget is computed for changed. A profile that is applied
    /// and never cleared lowers every budget for the process's life, and a
    /// stale session's late `clear` can take a live session's profile down;
    /// both are only visible if the transitions are events. The fields are a
    /// closed token, a byte count and a reason token — nothing here can carry
    /// content.
    ///
    /// `generation` is the lease's ordinal — the profile's own monotone
    /// counter, incremented on every application. It is what lets a capture
    /// pair a `cleared` (or an `expired`) with the `applied` it ends instead
    /// of guessing from ordering, and it tells a session that re-applied its
    /// profile while an old lease was still up from one that never churned at
    /// all.
    case sessionProfile(profile: ModelBudgetPolicy.SessionProfile?,
                        budgetBytes: UInt64?,
                        generation: UInt64,
                        reason: SessionProfileEventReason)
    /// A model whose own footprint exceeds the device class budget was
    /// admitted because refusing would break the app's primary function.
    /// Emitted so the condition is visible rather than silent.
    case soloOverBudget(slot: ModelSlot, liveBytes: UInt64, budgetBytes: UInt64)
    case memoryPressure(budgetBytes: UInt64, evicted: [ModelSlot])
    /// [MODEL-WARDEN] Step 1 — the transient term `T` became non-zero: a
    /// load site may now allocate `liveBytes` for `slot`. Paired with one of
    /// `reservationCommitted` / `reservationAbandoned`, so a capture can
    /// always account for every reservation it saw granted.
    case reserved(slot: ModelSlot,
                  liveBytes: UInt64,
                  purpose: ReservationPurpose,
                  isLargeLoad: Bool)
    /// [MODEL-WARDEN] Step 1 — a load was refused before allocating. The
    /// honest refusal the whole mechanism exists to make possible: the
    /// caller takes its own degraded path, and the capture says why.
    case reservationDenied(slot: ModelSlot,
                           reason: ReservationDenial,
                           purpose: ReservationPurpose)
    /// [MODEL-WARDEN] Step 1 — the model is in memory. The reservation is
    /// retired; the residency record is `didLoad`'s business, unchanged.
    case reservationCommitted(slot: ModelSlot, heldSeconds: TimeInterval)
    /// [MODEL-WARDEN] Step 1 — a granted reservation was handed back
    /// unspent, or reaped.
    case reservationAbandoned(slot: ModelSlot, reason: ReservationAbandonReason)
    /// [MODEL-WARDEN] Step 2 — a resident was *asked* for its bytes, and
    /// this is what it said. Emitted once per ask, including the refusals
    /// the warden obeyed: a capture that only saw the successful takes
    /// could not tell a slot that never refuses from a warden that never
    /// asks, which is the property the revocation protocol exists to make
    /// observable.
    case preempted(slot: ModelSlot, outcome: PreemptionOutcome)
    /// [MODEL-WARDEN] Step 2 — the thrash guard refused a load. See
    /// `ReservationDenial.thrashGuarded`; this is the same fact in the
    /// ledger's own vocabulary so a capture can count guard firings without
    /// having to join them against the reservation events.
    case thrashGuarded(slot: ModelSlot, kind: ThrashGuardKind, count: Int)
    /// [MODEL-WARDEN] Step 0 — a `phys_footprint` sample, taken at the
    /// moments the ledger changes shape (an admission, an eviction, a
    /// pressure level). The numbers ride together because neither is
    /// actionable alone: `phys_footprint` without `ceiling_bytes` says
    /// nothing about how close the app is to the kill, and `ceiling_bytes`
    /// without `phys_footprint` says nothing about how much is already
    /// spent.
    case footprintSample(physFootprintBytes: UInt64,
                         ceilingBytes: UInt64,
                         residentLiveBytes: UInt64,
                         transientLiveBytes: UInt64)
}

/// A point-in-time view of the ledger. For tests and diagnostics.
struct ModelLifecycleSnapshot: Equatable {
    let deviceClass: ModelLifecycleBudget.DeviceClass
    let budgetBytes: UInt64
    let effectiveBudgetBytes: UInt64
    let residentLiveBytes: UInt64
    /// [MODEL-WARDEN] Step 1 — `T(t)`: bytes reserved and not yet in
    /// memory. Before Step 1 there was no such quantity, which is why two
    /// admitted loads could allocate together.
    let transientLiveBytes: UInt64
    /// The reservations behind `transientLiveBytes`, newest last.
    let inFlight: [ModelReservation]
    /// The app's own footprint when the snapshot was taken. 0 when the
    /// probe could not read it.
    let physFootprintBytes: UInt64
    let resident: [ModelSlot]
    let pinned: [ModelSlot]
    /// [MODEL-WARDEN] Step 2 — the ladder position each registered slot
    /// holds. Reported so the field capture can say what the ordering was
    /// *of*, rather than inferring it from which slot happened to be
    /// evicted.
    let priorities: [ModelSlot: ModelPriority]
    /// [MODEL-WARDEN] Step 2 — slots the thrash guard is currently sparing
    /// from the load-driven victim order (cooldown or quarantine). The
    /// guard's firing is otherwise only visible in the denials it causes.
    let quarantined: [ModelSlot]

    /// [MODEL-WARDEN] Step 3 — the seconds the ordering prices each
    /// registered slot's reload at, measured p95 where a `load_ms` exists
    /// and the documented prior otherwise. Reported because the eviction
    /// order is otherwise invisible: a capture can see *who* was evicted
    /// but not what the warden thought it was trading away.
    let reloadCostSeconds: [ModelSlot: TimeInterval]

    /// [MODEL-WARDEN] Step 3 — the measured `W(t)` for the current class
    /// (the kernel's `phys_footprint` minus the ledger's own total), or
    /// `nil` before any sample. The class budget's premise, observable.
    let measuredWorkingSetBytes: UInt64?
}

// MARK: - The manager

/// **The single owner of heavy-model residency.**
///
/// Every heavy model load goes through `prepareLoad(of:modelID:)`, which
/// enforces a budget derived from `os_proc_available_memory()` — re-read at
/// every load — and evicts least-recently-used residents *before* the load
/// that would cross it. Eviction is a real unload: the manager holds a
/// release closure per slot, registered by the owning object, and calls it.
///
/// ### What this does NOT do
///
/// It does not load models, own them, or change what any of them do. It owns
/// one thing: the decision of whether the next model is allowed to become
/// resident, and who has to leave first. A slot's owner remains the only
/// object that touches the model itself.
///
/// ### Threading
///
/// All ledger state is behind one `NSLock`; the API is safe from any queue.
/// Release closures are invoked **outside** the lock (a non-recursive lock
/// plus a closure that called back in would deadlock, and `llama_model_free`
/// is not instant), so eviction is "tell the owner to drop it" followed by a
/// re-probe — see `prepareLoad`. Registering closures must capture their
/// owner weakly.
///
/// ### Why the ledger, not the owners, is the source of truth
///
/// A recognizer can drop its own model without telling anyone (it already
/// does — `WhisperKitSpeechRecognizer.releaseModel()` is called post-turn).
/// The ledger therefore tracks *intent*: `isResident` means "we admitted it
/// and have not evicted it since". Owners re-register residency by going
/// back through the gate on their next load, which is exactly the property
/// the idle-eviction and re-load paths depend on.
final class ModelLifecycleManager {

    /// The process-wide manager. `AppCoordinator` owns the lifetime; the
    /// recognizers hold it as the gate for their own loads.
    static let shared = ModelLifecycleManager()

    /// Default idle threshold: a heavy model unused for this long unloads.
    /// Two minutes is longer than any plausible inter-utterance gap in a
    /// conversation (the existing whisper post-turn TTL is 180 s for the
    /// same reason) and short enough that a phone put down after a turn
    /// gives its memory back.
    static let defaultIdleEvictionSeconds: TimeInterval = 120

    /// Under a level-2 warning the manager squeezes to this fraction of the
    /// class budget. Half is aggressive on purpose: a level-2 warning means
    /// the OS has already asked once, and the next thing it does is kill us.
    static let memoryPressureBudgetFraction: Double = 0.5

    private struct Entry {
        let footprint: ModelFootprint
        /// [MODEL-WARDEN] Step 3 — *which* artifact currently backs this
        /// slot. A slot is a pipeline position, not a file: `.speechToText`
        /// is the ANE WhisperKit graph (77 s to reload) on one run and a
        /// whisper.cpp q5 (2 s) on another, and the cost model's prior
        /// switches on exactly that. Without the id the two are the same
        /// row and the ordering would price them identically.
        var modelID: ModelID?
        weak var owner: AnyObject?
        let unload: () -> Void
        let evictable: Bool
        var isResident: Bool
        var loadedAt: Date
        var lastUse: Date
        var pinCount: Int
        /// [MODEL-WARDEN] Step 2 — where this resident sits on the ladder.
        /// Defaults to `.foreground`, which is what every registration that
        /// predates Step 2 meant: a feature's own handle, not a prefetch.
        let priority: ModelPriority
        /// [MODEL-WARDEN] Step 2 — the owner as something that can be
        /// *asked* (`ModelResident`), when it registered as one. The **box**
        /// is owned by the ledger; the resident inside it is weak, for the
        /// same reason `owner` is: a dead resident must not be kept alive by
        /// the ledger that noticed it died. (`entry.resident?.value` is the
        /// resident, and it is `nil` once the owner is gone.)
        ///
        /// `nil` is the normal case for most slots and is not a defect: a
        /// slot whose owner has no in-flight state to protect has nothing
        /// to say about being evicted, and the warden takes it through the
        /// registration's release closure exactly as it did before.
        var resident: ModelResidentBox?

        /// Whether the release contract permits the force fallback. Read
        /// from the footprint at registration so a decision never has to
        /// re-resolve the catalog.
        var allowsForcedUnload: Bool { footprint.releaseContract.allowsForcedUnload }
    }

    /// `ModelResident` is a class-only protocol that `Entry` wants to hold
    /// weakly, and the box is what makes that possible without making the
    /// ledger's own bookkeeping depend on the owner's lifetime.
    ///
    /// The direction matters and is the whole reason this is a class: the
    /// ledger holds the **box** strongly and the box holds the **resident**
    /// weakly. `weak var resident: ModelResident?` directly on `Entry` would
    /// look equivalent and is not — with nothing else retaining the box, the
    /// weak reference would be cleared on the way out of `register`, and
    /// every ask would silently find `nil`.
    final class ModelResidentBox {
        weak var value: ModelResident?
        init(_ value: ModelResident) { self.value = value }
    }

    /// [MODEL-WARDEN] A reservation's owner, held weakly so a dead owner's
    /// reservation is reapable rather than kept alive by the ledger that is
    /// supposed to notice it died.
    private struct WeakOwner {
        weak var value: AnyObject?
    }

    private let probe: MemoryProbing
    private let clock: () -> Date
    let idleEvictionSeconds: TimeInterval

    /// [MODEL-WARDEN] Step 1 — the load bounds. All configurable; see
    /// `ModelWardenConfig` for why each number is the number.
    var wardenConfig: ModelWardenConfig

    /// Test hook: pins the class budget so arithmetic is not at the mercy of
    /// the host machine's RAM. `nil` in production.
    private let budgetOverrideBytes: UInt64?
    /// [CAMERA-BUDGET] (2026-09-20) The active session profile's **lease**:
    /// what it is, the bytes it resolves to, who set it and when.
    ///
    /// A bare scalar on a process-wide singleton was the pre-review shape, and
    /// it had no answer to either failure the warden's reservation layer
    /// already solves: a `true` whose session ended without its `false`
    /// (interruption, backgrounding, a torn-down coordinator) lowered every
    /// budget for the process's life, and a *stale* session's late `false`
    /// cleared a live session's profile. So the profile is held the way
    /// reservations are held — the owner **weakly**, the moment **stamped** —
    /// and a lease whose owner is gone or that is older than
    /// `ModelWardenConfig.sessionProfileTTLSeconds` stops applying, with the
    /// reason reported (`SessionProfileEventReason`).
    private struct SessionProfileLease {
        let profile: ModelBudgetPolicy.SessionProfile
        let budgetBytes: UInt64
        /// `nil` means "no owner" — the process-level spelling a test uses.
        /// A box whose `value` is nil means the owning session was
        /// deallocated without clearing.
        let owner: WeakOwner?
        let setAt: Date
        /// Monotone per process, so a capture can pair a `cleared` with the
        /// `applied` it belongs to instead of guessing from ordering.
        let generation: UInt64
    }

    private var sessionProfileLease: SessionProfileLease?
    private var sessionProfileGeneration: UInt64 = 0

    /// [MODEL-WARDEN] Step 3 — what each resident costs to bring back, from
    /// measurements the app already takes.
    ///
    /// It lives here, behind this lock, rather than as a separate service,
    /// for one reason: **the reader and the writer must not be able to
    /// disagree**. The victim order and the idle sweep are computed under
    /// the same lock the readings are recorded under, so an ordering is
    /// always made against the same numbers a capture would report. A
    /// standalone cost service would need its own queue and would make
    /// "which cost did this decision use" a question with two answers.
    private var costModel = ModelCostModel()

    private let lock = NSLock()
    private var entries: [ModelSlot: Entry] = [:]
    private var idleTimer: DispatchSourceTimer?
    /// [MODEL-WARDEN] Step 1 — the in-flight half of the ledger: reservations
    /// granted and not yet committed or abandoned. This is `T(t)` in the
    /// proposal's `peak_footprint = M + T + W`.
    private var reservations: [UUID: ModelReservation] = [:]
    private var reservationOwners: [UUID: WeakOwner] = [:]
    /// [MODEL-WARDEN] Step 2 — the thrash guard's memory of load-driven
    /// evictions, per slot, all of it pruned by the window on every read.
    ///
    /// It counts *load-driven* evictions only (`.budget` and `.preemption`):
    /// from the victim's side, being taken to make room for someone else is
    /// one event whatever reason is recorded on it, while the idle sweep
    /// (a slot nobody is using) and the pressure sweeps (the OS asking) are
    /// different facts and dampening either would be the guard fighting the
    /// wrong thing.
    private struct ThrashRecord {
        /// Load-driven evictions inside `preemptionQuarantineSeconds`.
        var evictions: [Date] = []
        /// After a preemption the slot is kept out of the victim order
        /// until this instant — `preemptionCooldownSeconds`.
        var cooldownUntil: Date?
        /// After a refusal that cannot be forced, the slot is spared the
        /// ask until this instant — `unloadAckDeadlineSeconds`.
        var refusalGraceUntil: Date?
        /// Latched by `preemptionsBeforeQuarantine` evictions inside the
        /// window; lasts `preemptionQuarantineSeconds`.
        var quarantineUntil: Date?
    }

    private var thrash: [ModelSlot: ThrashRecord] = [:]
    /// Large-load reservations granted inside the rolling minute, for
    /// `ModelWardenConfig.maxLoadsPerMinute`.
    private var largeLoadAdmissions: [Date] = []

    /// The dispatch memory-pressure source (`.warning` / `.critical`), which
    /// the proposal records as "the closer-to-the-kernel signal" and which
    /// the tree did not use anywhere before Step 0.
    private var pressureSource: DispatchSourceMemoryPressure?

    /// [PRESSURE-SAFE LOAD] (2026-09-19) The most recent level the kernel
    /// reported, and when `.critical` last fired.
    ///
    /// Kept here rather than re-derived from `pressureSource.data` because the
    /// dispatch source's `data` is only meaningful *inside* its event handler
    /// — it is the event being delivered, not a stored level, and reading it
    /// later returns the last mask rather than the current state. A load gate
    /// asks at an arbitrary moment, so the ledger has to remember.
    private var pressureLevel: MemoryPressureLevel = .normal
    private var lastCriticalAt: Date?
    /// [PRESSURE-LATCH] (2026-09-19) When `.warning` last fired.
    ///
    /// The level alone is a latch on one of its two routes. The dispatch
    /// source (`startMemoryPressureMonitor`) sends `.normal` when pressure
    /// eases, and that is what clears the level — but the **UIKit** route
    /// (`didReceiveMemoryWarning` → `handleMemoryPressure()`) records
    /// `.warning` and has nothing that ever takes it back, so a single
    /// warning on a device where the source is not delivering leaves every
    /// later load refused for the rest of the process's life. The age is the
    /// second half of the fact, exactly as `lastCriticalAt` is for the
    /// timestamp half of `.critical`: the caller's own recency window decides
    /// what to do with it, and a report nobody has heard cleared stops
    /// gating once it is older than that window.
    private var lastWarningAt: Date?

    /// Bridged to the observability bus by the coordinator. Called outside
    /// the lock, on the caller's queue.
    var onEvent: ((ModelLifecycleEvent) -> Void)?

    init(probe: MemoryProbing = SystemMemoryProbe(),
         clock: @escaping () -> Date = { Date() },
         idleEvictionSeconds: TimeInterval = ModelLifecycleManager.defaultIdleEvictionSeconds,
         budgetOverrideBytes: UInt64? = nil,
         wardenConfig: ModelWardenConfig = .default) {
        self.probe = probe
        self.clock = clock
        self.idleEvictionSeconds = idleEvictionSeconds
        self.budgetOverrideBytes = budgetOverrideBytes
        self.wardenConfig = wardenConfig
    }

    // MARK: Registration

    /// Declares a slot and the release path that gets its memory back.
    /// Idempotent — re-registering refreshes the footprint and release
    /// closure without disturbing residency state.
    ///
    /// `owner` is held weakly purely so a dead owner's slot stops counting
    /// toward the budget; `unload` must capture its owner weakly too.
    func register(slot: ModelSlot,
                  modelID: ModelID?,
                  owner: AnyObject?,
                  evictable: Bool = true,
                  priority: ModelPriority = .foreground,
                  resident: ModelResident? = nil,
                  unload: @escaping () -> Void) {
        let footprint = ModelLifecycleInventory.footprint(for: slot, modelID: modelID)
        lock.lock()
        let now = clock()
        let box = resident.map(ModelResidentBox.init)
        if var existing = entries[slot] {
            existing = Entry(footprint: footprint,
                             modelID: modelID,
                             owner: owner,
                             unload: unload,
                             evictable: evictable,
                             isResident: existing.isResident,
                             loadedAt: existing.loadedAt,
                             lastUse: existing.lastUse,
                             pinCount: existing.pinCount,
                             priority: priority,
                             resident: box)
            entries[slot] = existing
        } else {
            entries[slot] = Entry(footprint: footprint,
                                  modelID: modelID,
                                  owner: owner,
                                  unload: unload,
                                  evictable: evictable,
                                  isResident: false,
                                  loadedAt: now,
                                  lastUse: now,
                                  pinCount: 0,
                                  priority: priority,
                                  resident: box)
        }
        lock.unlock()
    }

    /// Convenience for slots whose release path is a plain method.
    func register(slot: ModelSlot,
                  modelID: ModelID?,
                  owner: AnyObject?,
                  evictable: Bool = true,
                  priority: ModelPriority = .foreground,
                  resident: ModelResident? = nil,
                  release: @escaping (AnyObject) -> Void) {
        register(slot: slot, modelID: modelID, owner: owner,
                 evictable: evictable, priority: priority,
                 resident: resident) { [weak owner] in
            guard let owner else { return }
            release(owner)
        }
    }

    // MARK: The load gate

    /// Ask before loading. On `.allowed` the caller may proceed; on `.denied`
    /// it must take its existing failure path — the manager never makes a
    /// model loadable that is not.
    ///
    /// The sequence is the whole point of the design:
    ///
    /// 1. read the probe (every call — never a cached budget),
    /// 2. project `residentLive + incoming` against the budget,
    /// 3. pick LRU victims until it fits, MARK them non-resident,
    /// 4. release the lock, then actually unload the victims,
    /// 5. re-probe, and refuse only if the incoming model's *non-pageable*
    ///    bytes exceed the headroom that remains.
    ///
    /// Step 5 uses `hardBytes`, not `liveBytes`: a mmap'd GGUF's weight
    /// pages are the kernel's to reclaim, and refusing to load a 4B brain
    /// for bytes the OS would have paged out is how you brick a device that
    /// can in fact run it.
    func prepareLoad(of slot: ModelSlot, modelID: ModelID? = nil) -> LoadAdmission {
        // [MODEL-WARDEN] Step 1 — expressed in terms of reserve + commit,
        // exactly as the proposal prescribes. This is the SYNCHRONOUS fast
        // path: a caller that uses it is about to allocate immediately and
        // has nothing to wait for, so the reservation is granted and
        // retired in one breath and the transient term `T` is never
        // observable from outside. Migrated load sites use the two-phase
        // API instead, so their `T` is real for the length of the load.
        //
        // The events stay what they were before the reservation existed
        // (`admitted` / `denied` / `solo_over_budget`): this path's
        // decision is the same decision, and a capture that suddenly
        // reported one instant twice would make the field numbers harder to
        // read, not easier. The two-phase API is where the new
        // `reserved` / `reservation_*` vocabulary attaches.
        lock.lock()
        let registered = entries[slot] != nil
        lock.unlock()
        guard registered else {
            // No release path for this slot: the manager must not admit
            // residency it cannot undo. The reservation layer does not
            // change this — a permit to allocate with no way to take the
            // bytes back is exactly the shape the ledger refuses.
            onEvent?(.denied(slot: slot, reason: .unregisteredSlot))
            return .denied(.unregisteredSlot)
        }

        switch reserveInternal(ModelLoadRequest(slot: slot,
                                                modelID: modelID,
                                                purpose: .maintenance),
                               emittingEvents: false) {
        case .success(let reservation):
            commitInternal(reservation, emittingEvents: false)
            if reservation.soloOverBudget {
                onEvent?(.soloOverBudget(slot: slot,
                                         liveBytes: reservation.liveBytes,
                                         budgetBytes: reservation.budgetBytes))
            }
            onEvent?(.admitted(slot: slot,
                               liveBytes: reservation.liveBytes,
                               evicted: reservation.evicted))
            return .allowed(evicted: reservation.evicted)

        case .failure(let denial):
            let reason = Self.loadDenialReason(for: denial)
            onEvent?(.denied(slot: slot, reason: reason))
            return .denied(reason)
        }
    }

    /// The reservation denial as the admission vocabulary spells it. The two
    /// taxonomies answer different questions — the admission one is "may
    /// this slot become resident", the reservation one is "may this caller
    /// allocate now" — so the mapping is explicit rather than a shared enum
    /// with cases neither side means.
    private static func loadDenialReason(for denial: ReservationDenial) -> LoadDenialReason {
        switch denial {
        case .insufficientHeadroom:
            return .insufficientHeadroom
        case .budgetExhausted, .alreadyReserved, .loadInFlight, .thrashGuarded:
            // Something is holding the bytes or the queue. All of them are
            // "retry after the in-flight work settles", which is what
            // `budgetExhausted` already means to every caller — and the
            // thrash guard's refusals are the same sentence with a reason
            // (the `reservationDenied` event carries the guard's own
            // vocabulary for a capture that wants to count them).
            return .budgetExhausted
        case .overBudgetAlone:
            // Unreachable from `prepareLoad` (a replacing load is admitted
            // under `soloOverBudget` instead), mapped for exhaustiveness:
            // a model that cannot fit at all is the headroom refusal.
            return .insufficientHeadroom
        }
    }

    // MARK: - [MODEL-WARDEN] Step 1 — the reservation

    /// Ask permission to allocate, **before** allocating.
    ///
    /// Fail-fast by construction: there is no waiting state, no future to
    /// await and no queue to starve in. A caller that cannot be admitted is
    /// told so synchronously with a reason it can act on, and takes its own
    /// degraded path (whisper.cpp, the cloud tier, the dictionary). The
    /// alternative — parking the caller behind a 2.5 GB page-in — is how a
    /// feature ends up holding a turn open with no error and no answer,
    /// which is precisely the failure §2.4 of the proposal names.
    ///
    /// The order is the admission order (the same three phases
    /// `prepareLoad` documents), with the transient term added:
    ///
    /// 1. GC — reap expired reservations and dead owners;
    /// 2. decide under the lock — duplicate slot, serial slot, budget
    ///    (`residentLive + transientLive + incoming ≤ budget`), victims;
    /// 3. release the lock, then actually unload the victims;
    /// 4. re-probe and refuse if the incoming model's *non-pageable* bytes
    ///    exceed the headroom that remains;
    /// 5. record the reservation and hand back the permit.
    ///
    /// Step 2 adds the ladder to step 2 (victim selection) and the
    /// preemption ask between steps 2 and 3; Step 3's cost model reads the
    /// events. See the seam note at the foot of this file for what is
    /// deliberately not built.
    func reserve(_ request: ModelLoadRequest) -> Result<ModelReservation, ReservationDenial> {
        reserveInternal(request, emittingEvents: true)
    }

    private func reserveInternal(_ request: ModelLoadRequest,
                                 emittingEvents: Bool)
    -> Result<ModelReservation, ReservationDenial> {
        // [CAMERA-BUDGET] Report a session-profile lease that has stopped
        // applying **before** the admission arithmetic reads it: the read
        // prunes an expired lease silently (it runs under the lock, see
        // `sessionProfileBytesLocked`), so without this every admission would
        // be the place an expiry disappeared without a trace. Called outside
        // the lock, like the reaper's other call sites.
        reapExpiredSessionProfile()
        let incoming = ModelLifecycleInventory.footprint(for: request.slot,
                                                         modelID: request.modelID)
        let config = wardenConfig
        let now = clock()

        var victims: [ModelSlot] = []
        var preemptions: [PreemptionRecord] = []
        /// Slots whose bytes the warden must not take: their owner refused
        /// and the release contract does not permit overruling it. They are
        /// excluded from the rebuilt victim order, which is the whole
        /// difference between "the refusal was heard" and "the refusal was
        /// logged".
        var withheld: Set<ModelSlot> = []
        var denial: ReservationDenial?
        var soloOverBudget = false
        var budgetUsed: UInt64 = 0
        var reaped: [(reservation: ModelReservation,
                      reason: ReservationAbandonReason)] = []
        /// The state the SECOND victim walk must start from: everything the
        /// first walk decided is already reflected in `entries`, so the
        /// rebuild has to be told the arithmetic rather than re-derive it.
        var residentAfterFirstPlan: UInt64 = 0
        var transientLive: UInt64 = 0
        var excluding: ModelSlot?

        lock.lock()
        pruneDeadOwnersLocked()
        reaped = reapExpiredLocked(now: now)

        if let existing = reservations.values.first(where: { $0.slot == request.slot }) {
            // One pipeline position, one in-flight load. A second would be
            // admitted against a position that can hold one model, which is
            // the double-book the whole ledger exists to prevent — and it
            // is the shape two cycles of the same feature produce when a
            // stage deadline abandons a batch and the next tick re-asks.
            denial = .alreadyReserved(slot: request.slot, holder: existing.purpose)
        } else if let holder = serialHolderLocked(for: incoming, config: config) {
            // The serial load queue. Fail fast rather than queue: see the
            // method comment.
            denial = .loadInFlight(holder: holder)
        } else if let guarded = loadRateDenialLocked(for: request,
                                                     incoming: incoming,
                                                     now: now,
                                                     config: config) {
            // [MODEL-WARDEN] Step 2 — the global half of the thrash guard,
            // checked before any victim is chosen: a minute in which the
            // app has already admitted `maxLoadsPerMinute` large models is
            // not a minute in which one more will be the last.
            denial = guarded
        } else {
            let deviceClass = currentDeviceClassLocked()
            // See `ModelLoadRequest.replacesSlotContents`: a replacing load
            // excludes the slot's own residency (one position being
            // refilled); a peer load does not (the bytes are additive).
            let residentLive = request.replacesSlotContents
                ? residentLiveBytesLocked(excluding: request.slot)
                : residentLiveBytesLocked()
            transientLive = transientLiveBytesLocked()
            excluding = request.replacesSlotContents ? request.slot : nil
            // Two budgets, and the difference between them is the owner's
            // directive of 2026-09-19: "ModelWarden should UNLOAD other
            // models and load the translation model."
            //
            //  - `sessionBudget` is what `effectiveBudgetBytes` says *right
            //    now*: the class cap lowered by a tight probe reading. It is
            //    the right bound for a load whose bytes are purely additive
            //    to everyone else's, and it is what this manager has always
            //    judged.
            //  - `classBudget` is the promise the device class itself makes
            //    — 3.2 GB on the 6 GB phones. It is the bound a foreground
            //    translation load is judged against, because that load's own
            //    victims are exactly the room it needs.
            //
            // The Q8 translation head is 2.63 GB live against a 3.2 GB class
            // budget. A probe reading that put the session budget below it
            // made the tier's own load `over_budget_alone`, and the refusal
            // is what turned on-device translation into cloud-only. The
            // escape is bounded twice over, and neither bound is a hope:
            //
            //  - `incoming.liveBytes <= classBudget` — a model over the CLASS
            //    budget is over it whatever is evicted, so the 4B on a
            //    standard phone still meets `.overBudgetAlone` below.
            //  - phase 3, which re-probes after the eviction and refuses on
            //    `insufficientHeadroom` if the hard bytes are not really
            //    there. That check is what decides whether an allocation
            //    lands; the budget only decides whose bytes are spent first.
            //
            // `budgetOverrideBytes` pins both, so every test that fixes the
            // budget keeps the arithmetic it was written against.
            let sessionBudget = sessionBudgetLocked(deviceClass: deviceClass,
                                                    residentLiveBytes: residentLive)
            // [CAMERA-BUDGET] The escape hatch's bound is the CLASS budget —
            // the device class's own promise, which the session profile must
            // NOT lower. Lowering it here was the review's finding: on a
            // standard phone both budgets became 2.1 GB, the tier's own model
            // (2.63 GB live) exceeded both, and the escape hatch that exists
            // so the household's chosen brain is never unloadable refused the
            // translation model for the whole camera session —
            // `over_budget_alone`, on-device translation dead, the opposite of
            // what the profile was added for.
            //
            // The profile still does its job: `sessionBudget` above is the
            // bound every additive load is judged against, and the escaping
            // load's victim plan plus phase 3's re-probe still decide whether
            // the bytes are really there.
            let classBudget = classBudgetLocked(deviceClass: deviceClass)
            let budget = request.purpose.mayEvictPastTheSessionBudget
                && incoming.liveBytes <= classBudget
                ? classBudget
                : sessionBudget
            budgetUsed = budget

            let plan = planVictimsLocked(excluding: excluding,
                                         residentLive: residentLive,
                                         transientLive: transientLive,
                                         incomingLiveBytes: incoming.liveBytes,
                                         budget: budget,
                                         priority: request.priority,
                                         now: now,
                                         config: config,
                                         withheld: [])
            victims = plan.victims
            for victim in victims {
                // Marking non-resident here (rather than after the unload)
                // keeps the arithmetic honest even though the owner's free
                // may land later, keeps a second concurrent gate from
                // evicting the same slot twice, and — Step 2 — is what the
                // rebuilt victim order reads if an owner below refuses.
                //
                // The thrash counter is deliberately NOT bumped here: this
                // list can still lose members to a refusal below, and an
                // eviction that never happened must not count toward a
                // quarantine. The count is taken once, on the final list.
                markNonResidentLocked(victim)
            }
            residentAfterFirstPlan = plan.residentLive

            if !plan.fits {
                if incoming.liveBytes > budget {
                    // Over budget **on its own**: nothing eviction can do,
                    // because the walk above has already taken every victim
                    // it is allowed to. For a purpose that may evict past the
                    // session budget this branch is now reachable only when
                    // the model is over the CLASS budget — `budget` above is
                    // the class cap for such a request — which is the pinned
                    // half of the owner's directive: the 4B on a standard
                    // phone stays refused. A foreground translation load
                    // inside its class budget does not arrive here; it evicts
                    // and admits.
                    if request.replacesSlotContents && request.slot.admitsSoloOverBudget {
                        // Over budget on its own. Nothing we can evict
                        // changes that, and refusing would make the app's
                        // own default brain unloadable — admit it and
                        // announce the fact.
                        soloOverBudget = true
                    } else {
                        // No escape hatch to invoke. Either a PEER load —
                        // a second copy of something the device already
                        // cannot hold beside its neighbours, which the user
                        // did not ask for — or a replacing load on a
                        // position whose artifact the app can live without
                        // (`ModelSlot.admitsSoloOverBudget`), where the
                        // feature's own fallback is a working answer.
                        denial = .overBudgetAlone(liveBytes: incoming.liveBytes,
                                                  budgetBytes: budget)
                    }
                } else {
                    // It fits alone, but unevictable bytes are in the way:
                    // a resident is pinned (an inference is in flight), is
                    // not idle-evictable, or is being spared by the thrash
                    // guard. Admitting here would cross the budget
                    // silently, which is the one thing this whole mechanism
                    // exists to prevent — so refuse instead.
                    denial = budgetDenialLocked(victims: victims,
                                                slot: request.slot,
                                                now: now,
                                                config: config)
                }
            }
        }
        lock.unlock()

        // Emissions and evictions both happen outside the lock.
        if emittingEvents {
            for entry in reaped {
                onEvent?(.reservationAbandoned(slot: entry.reservation.slot,
                                               reason: entry.reason))
            }
        }

        // ---- Phase 2b — [MODEL-WARDEN] Step 2: ask before taking.
        //
        // The victims above are already marked non-resident, so a concurrent
        // gate sees them gone exactly as it did before Step 2. What is new
        // is that the ones whose owner registered as a `ModelResident` — and
        // whose priority is below the request's — get a say first. The ask
        // is outside the lock because a resident that called back in would
        // deadlock on the non-recursive lock, and the answer is what decides
        // whether the registered release closure is invoked unconditionally
        // (`.budget`) or only where the contract allows (`PreemptionOutcome`).
        //
        // A `.safetyCritical` request never asks: there is nothing above it
        // on the ladder, so `askableVictims` returns nothing for it and the
        // victims go through the Step 1 path unchanged.
        if denial == nil {
            let askable = askableVictims(victims: victims,
                                         above: request.priority)
            for (slot, resident) in askable {
                let outcome = resolvePreemption(slot: slot,
                                                resident: resident,
                                                now: now,
                                                config: config)
                preemptions.append(PreemptionRecord(slot: slot, outcome: outcome))
                if emittingEvents {
                    onEvent?(.preempted(slot: slot, outcome: outcome))
                }
                if !outcome.reclaimed { withheld.insert(slot) }
            }
        }

        // ---- Phase 2c — rebuild the victims around what was refused.
        //
        // Only the refusals that could not be forced change anything, and
        // when there are none this block is skipped entirely: the common path
        // asks nothing, rebuilds nothing, and pays one lock acquisition at
        // the end for the thrash count.
        //
        // One bound worth naming: the ask happens once per reservation,
        // against the FIRST plan's victim list. A slot that only becomes a
        // victim because a refusal pushed the order past it is evicted the
        // Step 1 way, without being asked — which is exactly where it would
        // have gone without Step 2, and the alternative (an ask-loop that
        // can cascade) buys a rarer guarantee at the cost of a path with no
        // fixed number of lock acquisitions.
        if !withheld.isEmpty {
            lock.lock()
            var withheldLive: UInt64 = 0
            for slot in withheld {
                // The warden is giving the bytes back to the ledger,
                // because it did not get them. Leaving them marked
                // non-resident would be the ledger counting memory it was
                // just told it cannot have.
                markResidentLocked(slot)
                withheldLive += entries[slot]?.footprint.liveBytes ?? 0
            }
            let rebuilt = planVictimsLocked(excluding: excluding,
                                            residentLive: residentAfterFirstPlan + withheldLive,
                                            transientLive: transientLive,
                                            incomingLiveBytes: incoming.liveBytes,
                                            budget: budgetUsed,
                                            priority: request.priority,
                                            now: now,
                                            config: config,
                                            withheld: withheld)
            victims += rebuilt.victims
            for victim in rebuilt.victims {
                markNonResidentLocked(victim)
            }
            // The first plan's victims included the refusals. They are not
            // victims any more: the registered release closure is exactly
            // what the owner just declined to have called, and Step 1's
            // unconditional path is what this protocol exists to replace.
            victims.removeAll { withheld.contains($0) }
            if !rebuilt.fits {
                denial = budgetDenialLocked(victims: victims,
                                            slot: request.slot,
                                            now: now,
                                            config: config)
            }
            lock.unlock()
        }

        // The thrash count, taken once on the final list — see the note in
        // phase 1. `withheld` slots are not in `victims` any more, so a
        // refusal is never counted as an eviction.
        lock.lock()
        for victim in victims {
            noteLoadDrivenEvictionLocked(victim, now: now, config: config)
        }
        lock.unlock()

        let handled: Set<ModelSlot> = Set(preemptions.filter { $0.outcome.reclaimed }
            .map(\.slot))
        for victim in victims where !handled.contains(victim) {
            performEviction(victim, reason: .budget)
        }

        if let denial {
            if emittingEvents {
                onEvent?(.reservationDenied(slot: request.slot,
                                            reason: denial,
                                            purpose: request.purpose))
                if let firing = denial.thrashGuardFiring {
                    onEvent?(.thrashGuarded(slot: firing.slot,
                                            kind: firing.kind,
                                            count: firing.count))
                }
            }
            return .failure(denial)
        }

        // Phase 3 — re-probe after eviction. Eviction is what makes room, so
        // the pre-eviction reading is not the one to judge by.
        let availableNow = probe.availableProcessMemoryBytes
        let unmanagedReserve = request.slot == .speechToText
            && !ModelLifecycleInventory.isWhisperKitModel(request.modelID)
            ? ModelLifecycleInventory.whisperCPPWedgedReserveBytes : 0
        if incoming.hardBytes + unmanagedReserve > availableNow {
            let denial = ReservationDenial.insufficientHeadroom(
                requiredBytes: incoming.hardBytes + unmanagedReserve,
                availableBytes: availableNow)
            if emittingEvents {
                onEvent?(.reservationDenied(slot: request.slot,
                                            reason: denial,
                                            purpose: request.purpose))
            }
            return .failure(denial)
        }

        let reservation = ModelReservation(
            id: UUID(),
            slot: request.slot,
            modelID: request.modelID,
            purpose: request.purpose,
            liveBytes: incoming.liveBytes,
            hardBytes: incoming.hardBytes,
            isLargeLoad: incoming.liveBytes >= config.largeLoadThresholdBytes,
            reservedAt: now,
            expiresAt: now.addingTimeInterval(config.reservationTTLSeconds),
            evicted: victims,
            soloOverBudget: soloOverBudget,
            budgetBytes: budgetUsed,
            priority: request.priority,
            preempted: preemptions)

        // Record under the lock, re-checking the two conditions another
        // caller could have created while the lock was down.
        lock.lock()
        if let existing = reservations.values.first(where: { $0.slot == request.slot }) {
            lock.unlock()
            let denial = ReservationDenial.alreadyReserved(slot: request.slot,
                                                           holder: existing.purpose)
            if emittingEvents {
                onEvent?(.reservationDenied(slot: request.slot,
                                            reason: denial,
                                            purpose: request.purpose))
            }
            return .failure(denial)
        }
        if let holder = serialHolderLocked(for: incoming, config: config) {
            lock.unlock()
            let denial = ReservationDenial.loadInFlight(holder: holder)
            if emittingEvents {
                onEvent?(.reservationDenied(slot: request.slot,
                                            reason: denial,
                                            purpose: request.purpose))
            }
            return .failure(denial)
        }
        reservations[reservation.id] = reservation
        if reservation.isLargeLoad {
            // [MODEL-WARDEN] Step 2 — the rolling minute behind
            // `maxLoadsPerMinute`. Counted here, where the grant is real:
            // a reservation that is granted and immediately abandoned still
            // cost the page-in the cap exists to bound.
            largeLoadAdmissions.append(now)
        }
        // Only an owner that exists can be observed to have died. A
        // reservation taken without one (a maintenance path, `prepareLoad`)
        // is reaped by the TTL, never by the owner check — recording a nil
        // owner would make every ownerless reservation look dead on the
        // next GC and withdraw a permit whose load is legitimately running.
        if let owner = request.owner {
            reservationOwners[reservation.id] = WeakOwner(value: owner)
        }
        lock.unlock()

        if emittingEvents {
            if soloOverBudget {
                onEvent?(.soloOverBudget(slot: request.slot,
                                         liveBytes: incoming.liveBytes,
                                         budgetBytes: budgetUsed))
            }
            onEvent?(.reserved(slot: request.slot,
                               liveBytes: incoming.liveBytes,
                               purpose: request.purpose,
                               isLargeLoad: reservation.isLargeLoad))
        }
        return .success(reservation)
    }

    /// The model is in memory. Retires the reservation; it does **not**
    /// record residency — that stays `didLoad`'s business, because the
    /// owner is the only object that knows the handle actually exists.
    ///
    /// A reservation that is no longer in the ledger (reaped by the TTL,
    /// or committed twice) is a no-op: the load landed into a state the
    /// warden had already given up on, and the kill switch for that is the
    /// event, not a crash.
    func commit(_ reservation: ModelReservation) {
        commitInternal(reservation, emittingEvents: true)
    }

    private func commitInternal(_ reservation: ModelReservation,
                                emittingEvents: Bool) {
        lock.lock()
        let held = reservations.removeValue(forKey: reservation.id)
        reservationOwners.removeValue(forKey: reservation.id)
        lock.unlock()
        guard let held, emittingEvents else { return }
        onEvent?(.reservationCommitted(
            slot: held.slot,
            heldSeconds: held.heldSeconds(at: clock())))
        // No footprint sample here. The permit is retired, but residency is
        // recorded by `didLoad` — which every load site calls the instant
        // the model lands, and which both spellings of the admission go
        // through. Sampling here would report the ledger *before* the
        // incoming bytes were in it, i.e. the number this event exists to
        // make comparable would be one step stale by construction.
    }

    /// Hand a granted reservation back unspent. The ordinary path is a
    /// `defer` at the load site: whatever the load did — returned, thrown,
    /// been cancelled — the permit is released on every exit, so `T` cannot
    /// outlive the attempt that created it.
    func abandon(_ reservation: ModelReservation,
                 reason: ReservationAbandonReason) {
        abandonInternal(reservation, reason: reason, emittingEvents: true)
    }

    /// Abandon every in-flight reservation for one slot, before a caller
    /// whose own load would collide with them starts allocating.
    ///
    /// [LOAD-SERIALIZATION] (2026-09-19) The translation tier calls this for
    /// `.speechToText` before its own load starts: the owner's 15:39 device
    /// capture shows an STT warm finishing its 85-second load in the same
    /// second the translation load was admitted, and two heavy page-ins at
    /// once are the exact spike the serial large-load bound exists to
    /// prevent. The warm is anticipatory (first-talk latency); the
    /// translation load answers the elder's live request, so the warm
    /// stands down and the recognizer re-loads on demand.
    ///
    /// Returns the abandoned reservations so the caller (or a test) can
    /// report what stood down. The load site detects the abandonment
    /// through `isReservationHeld(_:)` when its own load completes.
    @discardableResult
    func abandonInFlight(slot: ModelSlot,
                         reason: ReservationAbandonReason) -> [ModelReservation] {
        lock.lock()
        let targets = reservations.values.filter { $0.slot == slot }
        for reservation in targets {
            reservations.removeValue(forKey: reservation.id)
            reservationOwners.removeValue(forKey: reservation.id)
        }
        lock.unlock()
        for reservation in targets {
            onEvent?(.reservationAbandoned(slot: reservation.slot, reason: reason))
        }
        return targets
    }

    /// Whether a reservation is still held. Load sites ask this when their
    /// load completes, to detect a preemption that arrived mid-load
    /// ([LOAD-SERIALIZATION]): the permit was granted, the load began, and
    /// a colliding load abandoned it before this site committed. A gone
    /// reservation is the ledger's word that the bytes are no longer
    /// wanted, and the site stands down instead of committing residency.
    func isReservationHeld(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return reservations[id] != nil
    }

    /// [CAMERA-BUDGET] (2026-09-20) Set the session profile the model
    /// budget is computed for. While a camera translation session is
    /// active, the measured 1.4 GB camera working set lowers the budget by
    /// that amount (`ModelBudgetPolicy.sessionModelBudgetBytes(session:)`),
    /// so loads are judged — and pressure evictions sized — against the
    /// room that actually exists. `nil` restores the idle budget.
    ///
    /// The owner's 06:23 capture is the evidence: the brain was admitted,
    /// committed, and evicted for `memoryPressure` 0.7 s later because the
    /// resident set had no room the arithmetic could see. With the profile
    /// active, the warm STT resident is the first thing over the lowered
    /// budget — the trade the owner approved (2026-09-20): first talk
    /// after camera costs a load.
    /// `owner` is the object whose lifetime the profile belongs to — in
    /// production, the `LiveCameraSession` that reported the activation. It is
    /// held **weakly** (the same rule reservations use), so a session that
    /// goes away without clearing its profile stops gating the budget instead
    /// of lowering it for the process's life. A `nil` owner is the
    /// process-level spelling tests use.
    ///
    /// Passing `nil` clears the profile, and the clear is honoured **only for
    /// the owner that set it**: a stale session's late `false` cannot take a
    /// live session's profile down. Both the clear and the refusal are
    /// reported; so is a lease that expired on its own (see
    /// `reapExpiredSessionProfile(now:)`).
    ///
    /// `now` is injectable for the same reason `reapExpiredReservations` takes
    /// one: the TTL is a fact about a clock the tests own.
    func setSessionProfile(_ profile: ModelBudgetPolicy.SessionProfile?,
                           owner: AnyObject? = nil,
                           now: Date? = nil) {
        let reference = now ?? clock()
        // A lease that has already died is cleared before this call's own
        // outcome is decided, so the events tell the truth in order: the
        // expiry is reported as an expiry, and a clear that arrives after it
        // is a clear of nothing rather than a `refused_stale_owner` against a
        // profile that was never going to apply again.
        reapExpiredSessionProfile(now: reference)
        var event: ModelLifecycleEvent?
        lock.lock()
        if let profile {
            sessionProfileGeneration += 1
            let budgetBytes = ModelBudgetPolicy.policy(for: currentDeviceClassLocked())
                .sessionModelBudgetBytes(session: profile)
            sessionProfileLease = SessionProfileLease(
                profile: profile,
                budgetBytes: budgetBytes,
                owner: owner.map(WeakOwner.init),
                setAt: reference,
                generation: sessionProfileGeneration)
            event = .sessionProfile(profile: profile,
                                    budgetBytes: budgetBytes,
                                    generation: sessionProfileGeneration,
                                    reason: .applied)
        } else if let lease = sessionProfileLease {
            if Self.clearIsFromCurrentOwner(lease, clearer: owner) {
                sessionProfileLease = nil
                event = .sessionProfile(profile: nil,
                                        budgetBytes: nil,
                                        generation: lease.generation,
                                        reason: .cleared)
            } else {
                // A different object is clearing someone else's profile. The
                // profile stays exactly as it was, and the attempt is
                // reported rather than silently obeyed.
                event = .sessionProfile(profile: lease.profile,
                                        budgetBytes: lease.budgetBytes,
                                        generation: lease.generation,
                                        reason: .refusedStaleOwner)
            }
        }
        lock.unlock()
        if let event { onEvent?(event) }
    }

    /// Whether `clearer` may take `lease` down: the owner that set it, or the
    /// process-level spelling (no owner at all), which tests and any
    /// pre-owner call site use.
    private static func clearIsFromCurrentOwner(_ lease: SessionProfileLease,
                                                clearer: AnyObject?) -> Bool {
        guard let box = lease.owner else { return true }
        guard let clearer else { return false }
        return box.value === clearer
    }

    /// [CAMERA-BUDGET] Drop a session profile whose owner is gone or that has
    /// outlived its TTL, reporting which of the two it was.
    ///
    /// Public and clock-injected so tests drive it directly, exactly like
    /// `reapExpiredReservations(now:)`. It runs from the two memory-pressure
    /// handlers (which report the budget they *acted* on, so a lease that has
    /// stopped applying must not still be in the arithmetic), from
    /// `setSessionProfile` before it decides this call's outcome, and from
    /// `reserve` / `snapshot` — the two public reads of the budget. The last
    /// pair is what keeps the *reporting* complete: the read path prunes a
    /// stale lease silently, so without a reap before it an expiry would be
    /// dropped from the arithmetic with nothing in the capture saying so.
    ///
    /// Returns the reason when a lease was dropped, `nil` when there was
    /// nothing to reap.
    @discardableResult
    func reapExpiredSessionProfile(now: Date? = nil) -> SessionProfileEventReason? {
        let reference = now ?? clock()
        var reason: SessionProfileEventReason?
        var budgetBytes: UInt64?
        var generation: UInt64?
        lock.lock()
        if let lease = sessionProfileLease {
            if let expiry = Self.expiryReason(for: lease,
                                              now: reference,
                                              ttl: wardenConfig.sessionProfileTTLSeconds) {
                sessionProfileLease = nil
                reason = expiry
                budgetBytes = lease.budgetBytes
                generation = lease.generation
            }
        }
        lock.unlock()
        if let reason {
            onEvent?(.sessionProfile(profile: nil,
                                     budgetBytes: budgetBytes,
                                     generation: generation ?? 0,
                                     reason: reason))
        }
        return reason
    }

    /// Why a lease no longer applies, or `nil` while it does.
    private static func expiryReason(for lease: SessionProfileLease,
                                     now: Date,
                                     ttl: TimeInterval) -> SessionProfileEventReason? {
        if let box = lease.owner, box.value == nil { return .ownerReleased }
        return now.timeIntervalSince(lease.setAt) > ttl ? .expired : nil
    }

    private func abandonInternal(_ reservation: ModelReservation,
                                 reason: ReservationAbandonReason,
                                 emittingEvents: Bool) {
        lock.lock()
        let held = reservations.removeValue(forKey: reservation.id)
        reservationOwners.removeValue(forKey: reservation.id)
        lock.unlock()
        guard let held, emittingEvents else { return }
        onEvent?(.reservationAbandoned(slot: held.slot, reason: reason))
    }

    /// Reap every reservation that outlived `reservationTTLSeconds`, and
    /// report the ones that outlived `loadWatchdogSeconds` under their own
    /// louder reason.
    ///
    /// Public and clock-injected so tests drive it directly, exactly like
    /// `evictIdle(now:)`. Production also reaches it from the idle sweep and
    /// from the memory-pressure source, so an abandoned load is reaped
    /// without anyone having to ask.
    @discardableResult
    func reapExpiredReservations(now: Date? = nil) -> [ModelReservation] {
        let reference = now ?? clock()
        lock.lock()
        let expired = reapExpiredLocked(now: reference)
        lock.unlock()
        for entry in expired {
            onEvent?(.reservationAbandoned(slot: entry.reservation.slot,
                                           reason: entry.reason))
        }
        return expired.map(\.reservation)
    }

    /// The in-flight reservations, oldest first. Test and diagnostics seam.
    func inFlightReservations() -> [ModelReservation] {
        lock.lock()
        defer { lock.unlock() }
        return reservations.values.sorted { $0.reservedAt < $1.reservedAt }
    }

    /// GC under the lock: drop every reservation past its TTL, and every
    /// reservation whose owner has been deallocated. Returns the reaped
    /// values **with their reasons** so the caller can emit outside the lock
    /// — the reason is decided here, where the cause is still known, rather
    /// than reconstructed by the emitter from an age.
    private func reapExpiredLocked(now: Date)
    -> [(reservation: ModelReservation, reason: ReservationAbandonReason)] {
        var reaped: [(reservation: ModelReservation,
                      reason: ReservationAbandonReason)] = []
        for (id, reservation) in reservations {
            let ownerGone = reservationOwners[id].map { $0.value == nil } ?? false
            let age = reservation.heldSeconds(at: now)
            let reason: ReservationAbandonReason?
            if ownerGone {
                // The object that was going to commit this no longer
                // exists. That is not a load that failed; it is a load
                // nobody is waiting for.
                reason = .cancelled
            } else if age >= wardenConfig.loadWatchdogSeconds {
                reason = .watchdogExpired
            } else if reservation.expiresAt <= now {
                reason = .ttlExpired
            } else {
                reason = nil
            }
            guard let reason else { continue }
            reaped.append((reservation, reason))
            reservations.removeValue(forKey: id)
            reservationOwners.removeValue(forKey: id)
        }
        return reaped.sorted { $0.reservation.reservedAt < $1.reservation.reservedAt }
    }

    /// Whether the serial load queue can take this load, and who holds it if
    /// not. `nil` means yes.
    ///
    /// Large loads are capped at `maxConcurrentLargeLoads` (one) and small
    /// ones at `maxConcurrentSmallLoads`: the caps are separate because the
    /// quantity being bounded is different. A large load is a memory *and*
    /// CPU spike (§2.1 of the proposal — the observed kill was
    /// `cpu_resource_fatal`); a small one is only worth bounding so that
    /// "small" cannot quietly mean "unlimited".
    private func serialHolderLocked(for incoming: ModelFootprint,
                                    config: ModelWardenConfig) -> ModelSlot? {
        let isLarge = incoming.liveBytes >= config.largeLoadThresholdBytes
        let live = reservations.values.filter { $0.isLargeLoad == isLarge }
        let limit = isLarge ? config.maxConcurrentLargeLoads
                            : config.maxConcurrentSmallLoads
        guard live.count >= limit else { return nil }
        // The holder the caller is waiting behind: the one that got in
        // first, which is the one whose load is actually running.
        return live.min { $0.reservedAt < $1.reservedAt }?.slot
    }

    /// The transient term `T(t)`: bytes reserved and not yet in memory.
    private func transientLiveBytesLocked() -> UInt64 {
        reservations.values.reduce(UInt64(0)) { $0 + $1.liveBytes }
    }

    /// Which resident is actually blocking the load — the largest one that
    /// survived victim selection, i.e. the one that is pinned or not
    /// evictable. Named on the denial so the capture says *what* stood in
    /// the way rather than only that something did.
    private func blockerLocked(victims: [ModelSlot], slot: ModelSlot) -> ModelSlot {
        let blocked = entries.filter { entry in
            entry.value.isResident && !victims.contains(entry.key)
        }
        return blocked.max { $0.value.footprint.liveBytes < $1.value.footprint.liveBytes }?.key
            ?? slot
    }

    // MARK: - [MODEL-WARDEN] Step 2 — the ladder, preemption, the thrash guard

    /// The load-driven victim order: **lowest priority first, then heavy
    /// before light, then — Step 3 — the lowest residency value per second
    /// of reload cost.**
    ///
    /// This is `lruEvictionOrderLocked` with the ladder in front of it, and
    /// the two are deliberately separate functions. The pressure sweeps keep
    /// the plain LRU order: a level-2 warning is the OS asking for memory
    /// back and the honest response is "the biggest, least used thing
    /// first", not "re-litigate what each resident is for". The ladder is
    /// about *who the warden prefers to inconvenience*, which is a question
    /// only a load-driven eviction is asking.
    ///
    /// ### What Step 3 replaced, and what it deliberately did not
    ///
    /// The first two keys are Step 2's and are unchanged: the ladder is the
    /// ordering's first word, and heavy-before-light is still true here *in
    /// addition* to being enforced structurally in `planVictimsLocked`
    /// (`heavy + light`). What used to follow them was
    /// `(least recent first, bigger frees more)` — an ordinal rule that
    /// prices every resident's reload at zero, which is how an LRU sweep
    /// ends up buying 1 GB back for 77 s. It is now one scalar,
    /// `ModelCostModel.evictionPressure`: `idleSeconds × liveBytes ÷
    /// reloadCostSeconds`, descending. LRU and size are still both *in*
    /// there, weighted; the reload term is what is new.
    ///
    /// The two properties that follow are the ones the tests pin:
    ///
    ///  - **The ANE STT goes last among victims of equal residency value.**
    ///    Its 77 s reload makes its pressure ~15× smaller than a 2 GB
    ///    brain's at equal idleness, so it is not taken while a cheaper
    ///    heavy resident can close the gap. §7.4's accepted default ("only
    ///    under pressure or an explicit swap; never for an LRU sweep"), as
    ///    arithmetic rather than as a special case in the comparator.
    ///  - **It is still a victim when nothing else can close the gap.** The
    ///    order is a preference, not a protection: the 4B swap that needs
    ///    3.4 GB still walks past a sleeping brain and takes the STT, which
    ///    is the "STT and the 4B never co-reside" invariant the suite
    ///    already encodes.
    ///
    /// `config.costAwareEvictionEnabled == false` restores Step 2's exact
    /// comparator — the field-test switch for a capture that needs to A/B
    /// the ordering without a rebuild.
    private func loadEvictionOrderLocked(excluding excluded: ModelSlot?,
                                         priority: ModelPriority,
                                         now: Date,
                                         config: ModelWardenConfig,
                                         withheld: Set<ModelSlot>) -> [ModelSlot] {
        let spared = guardSparedLocked(now: now, config: config, priority: priority)
        let deviceClass = currentDeviceClassLocked()
        return entries.compactMap {
            slot, entry -> (ModelSlot, ModelPriority, Bool, Date, UInt64,
                            Double)? in
            guard entry.isResident, entry.evictable,
                  entry.pinCount == 0, slot != excluded,
                  entry.owner != nil, !withheld.contains(slot),
                  spared[slot] == nil else { return nil }
            let pressure = costModel.evictionPressure(
                slot: slot,
                modelID: entry.modelID,
                footprint: entry.footprint,
                deviceClass: deviceClass,
                idleSeconds: now.timeIntervalSince(entry.lastUse))
            return (slot, entry.priority, entry.footprint.isHeavy,
                    entry.lastUse, entry.footprint.liveBytes, pressure)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }     // lowest priority first
            if lhs.2 != rhs.2 { return lhs.2 && !rhs.2 }   // heavy before light
            if config.costAwareEvictionEnabled {
                // Step 3: the lowest residency value per second of reload
                // pain goes first. The ordinal pair below is still the
                // tie-break, so two residents with identical pressure (zero
                // idle time, say) order exactly as they did in Step 2.
                if lhs.5 != rhs.5 { return lhs.5 > rhs.5 }
            }
            if lhs.3 != rhs.3 { return lhs.3 < rhs.3 }     // least recent first
            return lhs.4 > rhs.4                           // bigger frees more
        }
        .map { $0.0 }
    }

    /// One walk of the victim order, **pure**: it decides, it does not
    /// mutate.
    ///
    /// Splitting the walk from the marking is what makes the refusal
    /// protocol possible without provisional state: a refusal invalidates
    /// the plan, and the answer is to walk again from the same inputs with
    /// the refused slots withheld — not to take the plan back.
    private func planVictimsLocked(excluding excluded: ModelSlot?,
                                   residentLive: UInt64,
                                   transientLive: UInt64,
                                   incomingLiveBytes: UInt64,
                                   budget: UInt64,
                                   priority: ModelPriority,
                                   now: Date,
                                   config: ModelWardenConfig,
                                   withheld: Set<ModelSlot>)
    -> (victims: [ModelSlot], fits: Bool, residentLive: UInt64) {
        var resident = residentLive
        let order = loadEvictionOrderLocked(excluding: excluded,
                                            priority: priority,
                                            now: now,
                                            config: config,
                                            withheld: withheld)
        let heavy = order.filter { entries[$0]?.footprint.isHeavy ?? false }
        // Light models are only candidates when evicting them can actually
        // close the gap. If the incoming model is over budget on its own,
        // nothing light can help, and taking the encoder would cost a CoreML
        // specialization for zero bytes — see the `soloOverBudget` branch.
        let light = incomingLiveBytes > budget
            ? []
            : order.filter { !(entries[$0]?.footprint.isHeavy ?? false) }

        var victims: [ModelSlot] = []
        for victim in heavy + light
        where resident + transientLive + incomingLiveBytes > budget {
            victims.append(victim)
            let bytes = entries[victim]?.footprint.liveBytes ?? 0
            // Saturating: the caller passes the resident total explicitly so
            // a second walk can be run against a ledger the first one has
            // already spent, and an under-count in either direction must not
            // be able to trap.
            resident = resident >= bytes ? resident - bytes : 0
        }
        return (victims,
                resident + transientLive + incomingLiveBytes <= budget,
                resident)
    }

    /// The victims whose owner can be asked, in victim order.
    ///
    /// Two conditions, both required: the owner registered as a
    /// `ModelResident`, and the resident's priority is **strictly below**
    /// the request's. The second is the ladder doing its job — a boot warm
    /// does not get to ask the camera's translation brain to stand down,
    /// because that trades a user-visible feature for a prefetch. It also
    /// means a `.safetyCritical` request is the only one that can ask
    /// anything at all: there is nothing above it.
    /// Not `…Locked`: it takes the lock itself, because its one caller reads
    /// the answer *before* the ask and the asks must happen outside the lock.
    /// Reading `entries` from the caller's side of that boundary would be the
    /// manager's only unsynchronised view of its own state.
    private func askableVictims(victims: [ModelSlot],
                                above priority: ModelPriority) -> [(ModelSlot, ModelResident)] {
        lock.lock()
        defer { lock.unlock() }
        return victims.compactMap { slot in
            guard let entry = entries[slot],
                  entry.priority < priority,
                  let resident = entry.resident?.value else { return nil }
            // A slot inside a refusal grace never reaches here: the grace is
            // enforced where every other sparing is, in the victim order
            // (`guardSparedLocked`). One mechanism, so a slot cannot be
            // spared from the order and then asked anyway.
            return (slot, resident)
        }
    }

    /// Ask, then decide what the answer permits.
    ///
    /// The call itself is outside the lock (see `ModelResident`); the
    /// bookkeeping that follows is under it. `forced` is legal exactly
    /// because `ModelReleaseContract.allowsForcedUnload` says the runtime
    /// survives the drop — which is the one rule this whole protocol will
    /// not bend, and the reason whisper.cpp's `perAttemptContext` can refuse
    /// and be *obeyed* while an `actorDeferredFree` llama handle cannot.
    private func resolvePreemption(slot: ModelSlot,
                                   resident: ModelResident,
                                   now: Date,
                                   config: ModelWardenConfig) -> PreemptionOutcome {
        let ack = resident.releaseForWarden()
        switch ack {
        case .released:
            lock.lock()
            notePreemptionLocked(slot, now: now, config: config)
            lock.unlock()
            return .released
        case .notHolding:
            // Nothing was there to drop. The bytes are accounted for either
            // way, and the cooldown is not owed: no handle was lost.
            return .alreadyReleased
        case .refused(let reason):
            lock.lock()
            let forceable = entries[slot]?.allowsForcedUnload ?? false
            if !forceable {
                noteRefusalGraceLocked(slot, now: now, config: config)
            }
            lock.unlock()
            guard forceable else { return .refused(reason: reason) }
            performEviction(slot, reason: .preemption)
            lock.lock()
            notePreemptionLocked(slot, now: now, config: config)
            lock.unlock()
            return .forced(reason: reason)
        }
    }

    /// The refusal a budget shortfall deserves, told apart from the guard's
    /// own refusal.
    ///
    /// When the only thing standing in the way is a slot the thrash guard is
    /// sparing, `.budgetExhausted` would be true but unhelpful: the field
    /// capture would read "something held the bytes" and could not tell a
    /// pin from the loop-breaker. The guard says so under its own name
    /// instead — and it is still a deferral, not a verdict.
    private func budgetDenialLocked(victims: [ModelSlot],
                                    slot: ModelSlot,
                                    now: Date,
                                    config: ModelWardenConfig) -> ReservationDenial {
        let blocker = blockerLocked(victims: victims, slot: slot)
        if let record = thrash[blocker] {
            let quarantined = record.quarantineUntil.map { $0 > now } ?? false
            let cooling = record.cooldownUntil.map { $0 > now } ?? false
            if quarantined || cooling {
                return .thrashGuarded(slot: blocker,
                                      kind: .victimSpared,
                                      count: record.evictions.count)
            }
        }
        return .budgetExhausted(by: blocker)
    }

    /// The global half of the guard: large loads admitted inside the rolling
    /// minute. Returns a denial when the window is already full.
    ///
    /// Exempt, both deliberately: a `.maintenance` load (the synchronous
    /// `prepareLoad` fast path, which is not a feature loop) and a
    /// `.safetyCritical` one (a live voice turn — the household is waiting,
    /// and the guard exists to damp churn, not to stand between the user and
    /// an answer).
    private func loadRateDenialLocked(for request: ModelLoadRequest,
                                      incoming: ModelFootprint,
                                      now: Date,
                                      config: ModelWardenConfig) -> ReservationDenial? {
        guard config.thrashGuardEnabled,
              incoming.liveBytes >= config.largeLoadThresholdBytes,
              request.purpose != .maintenance,
              request.priority != .safetyCritical else { return nil }
        pruneLargeLoadAdmissionsLocked(now: now)
        let window = largeLoadAdmissions.count
        guard window >= config.maxLoadsPerMinute else { return nil }
        return .thrashGuarded(slot: request.slot,
                              kind: .loadRateExceeded,
                              count: window)
    }

    /// Slots the guard is currently keeping out of the load-driven victim
    /// order, and the number behind it.
    ///
    /// Three things spare a slot, and they are different sentences:
    /// a **quarantine** (evicted too often inside the window), a
    /// **cooldown** (just preempted — taking the bytes straight back is the
    /// loop), and a **refusal grace** (the owner said no and the contract
    /// agreed). All three are load-driven-only: a memory warning or an idle
    /// sweep ignores them, because the guard damps feature churn and not the
    /// OS's request for memory.
    private func guardSparedLocked(now: Date,
                                   config: ModelWardenConfig,
                                   priority: ModelPriority) -> [ModelSlot: Int] {
        guard config.thrashGuardEnabled, priority != .safetyCritical else {
            // A live voice turn is never refused for the guard's sake. See
            // `loadRateDenialLocked`.
            return [:]
        }
        var spared: [ModelSlot: Int] = [:]
        for (slot, record) in thrash {
            let held = (record.quarantineUntil.map { $0 > now } ?? false)
                || (record.cooldownUntil.map { $0 > now } ?? false)
                || (record.refusalGraceUntil.map { $0 > now } ?? false)
            if held { spared[slot] = record.evictions.count }
        }
        return spared
    }

    /// One load-driven eviction of `slot`, for the quarantine count.
    ///
    /// Counted here and nowhere else: `didUnload`, the idle sweep and the
    /// pressure sweeps also clear residency, and none of them is the loop
    /// the guard exists to break.
    private func noteLoadDrivenEvictionLocked(_ slot: ModelSlot,
                                              now: Date,
                                              config: ModelWardenConfig) {
        guard config.thrashGuardEnabled else { return }
        var record = thrash[slot] ?? ThrashRecord()
        record.evictions = record.evictions.filter {
            now.timeIntervalSince($0) < config.preemptionQuarantineSeconds
        }
        record.evictions.append(now)
        if record.evictions.count >= config.preemptionsBeforeQuarantine {
            record.quarantineUntil = now.addingTimeInterval(
                config.preemptionQuarantineSeconds)
            // Cleared on latch, so the quarantine does not re-arm itself the
            // moment it expires.
            record.evictions.removeAll()
        }
        thrash[slot] = record
    }

    /// A slot was preempted: keep it out of the victim order for the
    /// cooldown, so the bytes cannot be taken back the instant they were
    /// given up.
    private func notePreemptionLocked(_ slot: ModelSlot,
                                      now: Date,
                                      config: ModelWardenConfig) {
        guard config.thrashGuardEnabled else { return }
        var record = thrash[slot] ?? ThrashRecord()
        record.cooldownUntil = now.addingTimeInterval(config.preemptionCooldownSeconds)
        thrash[slot] = record
    }

    /// A refusal the warden obeyed: spare the slot the ask for the ack
    /// deadline, so a busy owner is not asked once per pipeline tick.
    private func noteRefusalGraceLocked(_ slot: ModelSlot,
                                        now: Date,
                                        config: ModelWardenConfig) {
        guard config.thrashGuardEnabled else { return }
        var record = thrash[slot] ?? ThrashRecord()
        record.refusalGraceUntil = now.addingTimeInterval(config.unloadAckDeadlineSeconds)
        thrash[slot] = record
    }

    private func pruneLargeLoadAdmissionsLocked(now: Date) {
        largeLoadAdmissions.removeAll { now.timeIntervalSince($0) >= 60 }
    }

    /// The inverse of `markNonResidentLocked`, and it exists for exactly one
    /// caller: a refusal hands the bytes *back* to the ledger, and the
    /// second walk has to see them.
    private func markResidentLocked(_ slot: ModelSlot) {
        guard var entry = entries[slot] else { return }
        entry.isResident = true
        entries[slot] = entry
    }

    /// Record that the load actually happened. Called by the owner once the
    /// model is in memory — not by `prepareLoad`, which only decides.
    ///
    /// `owner` is optional and exists for the one slot with two possible
    /// owners: `.speechToText` is backed by `WhisperKitSpeechRecognizer` on
    /// the ANE path and `WhisperSpeechRecognizer` on the whisper.cpp path,
    /// and both are constructed by the coordinator. Whichever registers
    /// last owns the slot, so a residency update from the other one must be
    /// ignored rather than clobbering the live engine's state.
    func didLoad(_ slot: ModelSlot, owner: AnyObject? = nil) {
        lock.lock()
        guard var entry = entries[slot] else {
            lock.unlock()
            return
        }
        if let owner, !isOwned(entry, by: owner) {
            lock.unlock()
            return
        }
        // [MODEL-WARDEN] Step 0 — this is where the ledger changes shape,
        // so this is where the kernel's own footprint is worth reading. The
        // transition (not every `didLoad`) is the moment the bytes appeared:
        // an owner that re-reports a load it already made must not turn into
        // a second sample of the same instant.
        let becameResident = !entry.isResident
        let now = clock()
        entry.isResident = true
        entry.loadedAt = now
        entry.lastUse = now
        entries[slot] = entry
        lock.unlock()
        if becameResident { sampleFootprint() }
    }

    private func isOwned(_ entry: Entry, by owner: AnyObject) -> Bool {
        entry.owner === owner
    }

    /// Record that the owner dropped the model on its own — post-turn
    /// release, a preference change, a teardown. Without this the ledger
    /// would keep counting bytes that are already back, and would refuse a
    /// later load for room it actually has.
    ///
    /// Distinct from `evict(_:reason:)`: eviction CALLS the owner's release
    /// path, so calling it from that path would recurse.
    ///
    /// `owner` is owner-scoped for the same reason as `didLoad` — see there.
    func didUnload(_ slot: ModelSlot, owner: AnyObject? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let owner, let entry = entries[slot], !isOwned(entry, by: owner) {
            return
        }
        markNonResidentLocked(slot)
    }

    /// LRU touch. Call on every real use (a transcript, an interpreted
    /// command) so idle eviction measures idleness, not admission order.
    func noteUse(of slot: ModelSlot) {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[slot], entry.isResident else { return }
        entry.lastUse = clock()
        entries[slot] = entry
    }

    /// Pin a slot for the duration of an operation that must not have its
    /// model pulled out from under it (an in-flight inference). Pinned
    /// slots are skipped by every eviction path.
    func beginUse(of slot: ModelSlot) {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[slot] else { return }
        entry.pinCount += 1
        entry.lastUse = clock()
        entries[slot] = entry
    }

    func endUse(of slot: ModelSlot) {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[slot] else { return }
        entry.pinCount = max(0, entry.pinCount - 1)
        entry.lastUse = clock()
        entries[slot] = entry
    }

    // MARK: Eviction paths

    /// Unload one slot now (model swap, explicit teardown).
    func evict(_ slot: ModelSlot, reason: EvictionReason = .explicit) {
        lock.lock()
        let resident = entries[slot]?.isResident ?? false
        markNonResidentLocked(slot)
        lock.unlock()
        guard resident else { return }
        performEviction(slot, reason: reason)
    }

    /// Idle sweep: unload every evictable heavy model whose last use is
    /// older than its own idle threshold. The clock is injected, so tests
    /// drive this directly instead of waiting.
    ///
    /// [MODEL-WARDEN] Step 3 — the threshold is **per resident** and derived,
    /// not one constant for every slot:
    ///
    ///     threshold = max(idleEvictionSeconds, reloadCostSeconds / penalty)
    ///
    /// A resident whose reload outlasts the shipped window is worth holding
    /// through it, and the resident where that bites is the ANE STT (77 s
    /// prior, and 135 s after a failed ANE compile) sitting under a 120 s
    /// sweep that would otherwise pick the one moment the household is
    /// between turns to throw away a graph it will then wait 77 s to rebuild.
    ///
    /// Two properties keep this honest and keep Step 3 out of the TTL's way,
    /// both pinned by tests:
    ///
    ///  - **The configured base is a floor.** With the prior at 77 s and the
    ///    penalty at 1.0 the derived window is *below* 120 s, so every
    ///    shipped threshold and every existing idle-sweep test is unmoved;
    ///    only a measurement longer than the base moves anything.
    ///  - **A pressed working set suppresses the extension entirely** —
    ///    see `workingSetIsPressedLocked`. An app whose own footprint has
    ///    grown past the class's assumption must not respond by holding
    ///    models longer.
    ///
    /// The sweep is also the one place the warden releases a resident for
    /// *no* reason, which is why §7.4's "never for an LRU sweep" is about
    /// the ordering rather than about disabling this path: the sweep still
    /// takes the ANE STT at 120 s in the shipped configuration, and what the
    /// cost model adds is a reason for a measured resident to be held longer.
    @discardableResult
    func evictIdle(now: Date? = nil) -> [ModelSlot] {
        let reference = now ?? clock()
        // [MODEL-WARDEN] Step 1 — the idle sweep is also the reservation
        // reaper. A load that was granted and then abandoned (the tier's
        // losing stage, a cancelled turn) must not keep its bytes counted
        // as `T` until the next unrelated load happens to trigger the GC.
        reapExpiredReservations(now: reference)
        lock.lock()
        pruneDeadOwnersLocked()
        let deviceClass = currentDeviceClassLocked()
        let pressed = workingSetIsPressedLocked(for: deviceClass)
        let penalty = wardenConfig.idleEvictionPenalty
        let idle = entries.compactMap { slot, entry -> ModelSlot? in
            guard entry.isResident, entry.evictable,
                  entry.pinCount == 0, entry.footprint.isHeavy else { return nil }
            let unusedFor = reference.timeIntervalSince(entry.lastUse)
            let threshold = costModel.idleThresholdSeconds(
                slot: slot,
                modelID: entry.modelID,
                footprint: entry.footprint,
                deviceClass: deviceClass,
                configuredBase: idleEvictionSeconds,
                idleEvictionPenalty: penalty,
                workingSetIsPressed: pressed)
            return unusedFor >= threshold ? slot : nil
        }
        idle.forEach { markNonResidentLocked($0) }
        lock.unlock()

        for slot in idle { performEviction(slot, reason: .idle) }
        return idle
    }

    /// Level-2 memory warning. Squeeze to half the class budget, evicting
    /// LRU heavy models until the resident total is under it. Light models
    /// are left alone — the encoder has its own level-2 handler and the
    /// corrector cannot be unloaded at all.
    ///
    /// [PRESSURE-SAFE LOAD] (2026-09-19) Routing here records `.warning` as
    /// the current level. This is the UIKit path (`didReceiveMemoryWarning`),
    /// which the app already treats as equivalent to the kernel's `.warning` —
    /// and a load gate that only heard the dispatch source would miss every
    /// warning on a device where that source failed to install.
    @discardableResult
    func handleMemoryPressure() -> [ModelSlot] {
        recordPressureLevel(.warning)
        // [CAMERA-BUDGET] A pressure moment is where a leaked session lease
        // costs the most, so it is also where the lease is reported rather
        // than silently lifted: an owner that went away, or a profile nobody
        // cleared, is named here instead of lowering the budget unseen.
        reapExpiredSessionProfile()
        lock.lock()
        pruneDeadOwnersLocked()
        // The profile is included: with a camera session live the squeeze has
        // to be computed from the budget the session actually lowered, or the
        // response is sized for a working set that is not on screen.
        let fullBudget = profileAdjustedClassBudgetLocked(
            deviceClass: currentDeviceClassLocked())
        let budget = UInt64(Double(fullBudget)
            * ModelLifecycleManager.memoryPressureBudgetFraction)

        var victims: [ModelSlot] = []
        var residentLive = residentLiveBytesLocked()
        for slot in lruEvictionOrderLocked(excluding: nil) {
            guard residentLive > budget else { break }
            victims.append(slot)
            residentLive -= entries[slot]?.footprint.liveBytes ?? 0
            markNonResidentLocked(slot)
        }
        lock.unlock()

        for slot in victims { performEviction(slot, reason: .memoryPressure) }
        onEvent?(.memoryPressure(budgetBytes: budget, evicted: victims))
        sampleFootprint()
        return victims
    }

    // MARK: [MODEL-WARDEN] Step 0 — the kernel's memory-pressure level

    /// Start observing kernel memory pressure. Idempotent.
    ///
    /// Why a *dispatch source* when the app already handles
    /// `UIApplication.didReceiveMemoryWarningNotification`: the notification
    /// is UIKit relaying the kernel's `.warning`, and it arrives later and
    /// with the level already lost. The source gives the level, and gives
    /// `.critical` — which the notification path cannot distinguish — enough
    /// warning to decline a load that has not allocated yet.
    ///
    /// Off by default; `AppCoordinator.startModelLifecycle()` starts it, the
    /// same way it starts the idle timer, so tests and the simulator never
    /// race a kernel signal.
    func startMemoryPressureMonitor(queue: DispatchQueue = .main) {
        lock.lock()
        let alreadyMonitoring = pressureSource != nil
        lock.unlock()
        guard !alreadyMonitoring else { return }

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, let event = self.pressureSource?.data else { return }
            // The mask is an OptionSet and the bits can arrive together, so
            // read the most severe set bit rather than matching equality:
            // `.critical` must never be missed because `.warning` was also
            // set on the same event.
            let level: MemoryPressureLevel
            if event.contains(.critical) {
                level = .critical
            } else if event.contains(.warning) {
                level = .warning
            } else {
                level = .normal
            }
            self.handleMemoryPressure(level: level)
        }
        lock.lock()
        pressureSource = source
        lock.unlock()
        source.activate()
    }

    func stopMemoryPressureMonitor() {
        lock.lock()
        let source = pressureSource
        pressureSource = nil
        lock.unlock()
        source?.cancel()
    }

    /// Route a kernel pressure level to the response it deserves.
    ///
    /// `.warning` is exactly the existing level-2 squeeze — the app has been
    /// asked once and half the budget is the answer it already gave.
    /// `.critical` is strictly more: every evictable resident goes (not just
    /// the heavy ones — the encoder's CoreML specialization is worth less
    /// than surviving), and every uncommitted reservation is *cancelled*,
    /// because a reservation is a permission to create a spike and this is
    /// the one instant where the honest answer is to withdraw it. A caller
    /// that has already been granted one sees `reservationAbandoned` and
    /// takes its degraded path; nothing is silently re-queued.
    /// [PRESSURE-SAFE LOAD] (2026-09-19) The level is recorded on the way in,
    /// before anything is evicted, so a load gate that runs *while* this is
    /// still working through its victims already sees the new state. That
    /// ordering is the point: the eviction sweep runs release closures
    /// (`llama_model_free` is not instant), and a load that starts during that
    /// window must be refused by the level that caused the sweep, not by the
    /// level that preceded it.
    @discardableResult
    func handleMemoryPressure(level: MemoryPressureLevel) -> [ModelSlot] {
        recordPressureLevel(level)
        switch level {
        case .normal:
            return []
        case .warning:
            return handleMemoryPressure()
        case .critical:
            return handleCriticalMemoryPressure()
        }
    }

    // MARK: [PRESSURE-SAFE LOAD] — the load gate's reading

    /// Records a level the kernel — or UIKit, on the `handleMemoryPressure()`
    /// path — has reported. Under the lock, because a load gate reads the pair
    /// together and must never see a new level beside a stale timestamp.
    ///
    /// `.normal` clears the *level* and deliberately leaves `lastCriticalAt`
    /// alone: "the kernel is happy now" and "the kernel was about to kill us
    /// four seconds ago" are both true at once, and a load that started in
    /// that instant is exactly the load the recency window exists to refuse.
    /// Nothing clears the timestamp; it ages out through the caller's window.
    private func recordPressureLevel(_ level: MemoryPressureLevel) {
        lock.lock()
        defer { lock.unlock() }
        pressureLevel = level
        let now = clock()
        if level == .critical { lastCriticalAt = now }
        // [PRESSURE-LATCH] The warning's own age, stamped on both routes that
        // can record one. `.normal` deliberately does not clear it — the same
        // rule `lastCriticalAt` lives under: "the kernel is happy now" and "it
        // was unhappy a moment ago" are both true at once, and the age is what
        // lets a caller tell a report it has just been handed from one it has
        // been sitting on.
        if level == .warning { lastWarningAt = now }
    }

    /// The kernel's memory-pressure state as this manager last observed it.
    ///
    /// A snapshot, not a subscription: a caller asks before it allocates and
    /// gets the pair (level, age of the last `.critical`). The **window** that
    /// turns that pair into a decision belongs to the caller — see
    /// `MemoryPressureReading` for why it is not here.
    func memoryPressureReading() -> MemoryPressureReading {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        return MemoryPressureReading(
            level: pressureLevel,
            secondsSinceCritical: lastCriticalAt.map { now.timeIntervalSince($0) },
            secondsSinceWarning: lastWarningAt.map { now.timeIntervalSince($0) })
    }

    @discardableResult
    private func handleCriticalMemoryPressure() -> [ModelSlot] {
        // 1. Withdraw every permission to allocate that has not been spent.
        //    A reservation is a licence to create a spike, and this is the
        //    instant the licence must be withdrawn — the caller is told and
        //    takes its own degraded path; nothing is silently re-queued.
        // 2. Then evict EVERY evictable resident, not just down to the
        //    squeeze budget. `lruEvictionOrderLocked` already returns the
        //    whole list — heavy first, then the light models the `.warning`
        //    path spares — and it still honours pins and `evictable`, which
        //    is the right line even here: a pinned slot is mid-inference
        //    (freeing it would be a use-after-free) and a non-evictable one
        //    has no release path to call.
        reapExpiredSessionProfile()
        lock.lock()
        pruneDeadOwnersLocked()
        let pending = reservations.values.sorted { $0.reservedAt < $1.reservedAt }
        reservations.removeAll()
        reservationOwners.removeAll()
        var victims: [ModelSlot] = []
        for slot in lruEvictionOrderLocked(excluding: nil) {
            victims.append(slot)
            markNonResidentLocked(slot)
        }
        // [CAMERA-BUDGET] The profile is part of the reported number. It was
        // omitted here, so a `.critical` event during a camera session named
        // the CLASS budget while the warden was judging loads against the
        // session one — a capture reading the number would have concluded the
        // budget was 1.1 GB larger than it was.
        let budget = profileAdjustedClassBudgetLocked(
            deviceClass: currentDeviceClassLocked())
        lock.unlock()

        for reservation in pending {
            onEvent?(.reservationAbandoned(slot: reservation.slot,
                                           reason: .memoryPressure))
        }
        for slot in victims { performEviction(slot, reason: .criticalPressure) }
        onEvent?(.memoryPressure(budgetBytes: budget, evicted: victims))
        sampleFootprint()
        return victims
    }

    // MARK: Scene phase

    /// Withdraw every uncommitted reservation without touching a resident.
    ///
    /// The backgrounding half of the reservation contract: iOS gives a
    /// backgrounded app a much smaller jetsam limit and no guarantee that
    /// the work a reservation was taken for will ever run to completion, so
    /// a permission to allocate must not outlive the foreground. Distinct
    /// from `handleCriticalMemoryPressure()` on purpose — that one also
    /// evicts, and evicting a resident on a background transition would
    /// cost the ANE specialization for a pressure signal that has not
    /// arrived.
    ///
    /// A committed load is untouched: it is resident, and residency is
    /// `evict`'s business.
    ///
    /// The reaper's TTL is the backstop for a reservation that nobody
    /// withdraws; this is the deliberate withdrawal, so the caller's
    /// `reserve` that gets re-issued on the next activation starts from a
    /// clean transient term.
    @discardableResult
    func cancelPendingReservations(reason: ReservationAbandonReason)
    -> [ModelReservation] {
        lock.lock()
        pruneDeadOwnersLocked()
        let pending = reservations.values.sorted { $0.reservedAt < $1.reservedAt }
        reservations.removeAll()
        reservationOwners.removeAll()
        lock.unlock()

        for reservation in pending {
            onEvent?(.reservationAbandoned(slot: reservation.slot, reason: reason))
        }
        return pending
    }

    // MARK: Idle timer

    /// Starts the periodic idle sweep. Off by default so tests and the
    /// simulator never race a timer; `AppCoordinator` starts it in `start()`.
    func startIdleTimer(queue: DispatchQueue = .main,
                        interval: TimeInterval? = nil) {
        lock.lock()
        let alreadyRunning = idleTimer != nil
        lock.unlock()
        guard !alreadyRunning else { return }

        let period = interval ?? max(1, idleEvictionSeconds / 2)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + period, repeating: period, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            _ = self.evictIdle()
        }
        lock.lock()
        idleTimer = timer
        lock.unlock()
        timer.resume()
    }

    func stopIdleTimer() {
        lock.lock()
        let timer = idleTimer
        idleTimer = nil
        lock.unlock()
        timer?.cancel()
    }

    // MARK: Introspection

    func snapshot() -> ModelLifecycleSnapshot {
        // [CAMERA-BUDGET] The same reason the admission path reaps first: an
        // expiry the read discovers must be *reported*, and this is the read
        // a capture goes through. Outside the lock — the reaper takes it, and
        // the `defer` below is not yet in scope here.
        reapExpiredSessionProfile()
        lock.lock()
        defer { lock.unlock() }
        pruneDeadOwnersLocked()
        let deviceClass = currentDeviceClassLocked()
        let residentLive = residentLiveBytesLocked()
        let budget = sessionBudgetLocked(deviceClass: deviceClass,
                                         residentLiveBytes: residentLive)
        return ModelLifecycleSnapshot(
            deviceClass: deviceClass,
            budgetBytes: profileAdjustedClassBudgetLocked(deviceClass: deviceClass),
            effectiveBudgetBytes: budget,
            residentLiveBytes: residentLive,
            transientLiveBytes: transientLiveBytesLocked(),
            inFlight: reservations.values.sorted { $0.reservedAt < $1.reservedAt },
            physFootprintBytes: probe.physFootprintBytes,
            resident: entries.filter { $0.value.isResident }
                .map { $0.key }.sorted { $0.rawValue < $1.rawValue },
            pinned: entries.filter { $0.value.pinCount > 0 }
                .map { $0.key }.sorted { $0.rawValue < $1.rawValue },
            priorities: entries.mapValues(\.priority),
            quarantined: guardSparedLocked(now: clock(),
                                           config: wardenConfig,
                                           priority: .foreground)
                .keys.sorted { $0.rawValue < $1.rawValue },
            reloadCostSeconds: reloadCostsLocked(deviceClass: deviceClass),
            measuredWorkingSetBytes: costModel.workingSetBytes(for: deviceClass))
    }

    /// The reload cost the ordering would use for each registered slot.
    /// Finite entries only: `.processLifetime` slots have no reload to price
    /// and reporting them as `infinity` would put a value in the snapshot
    /// that no arithmetic can consume.
    private func reloadCostsLocked(
        deviceClass: ModelLifecycleBudget.DeviceClass) -> [ModelSlot: TimeInterval] {
        var costs: [ModelSlot: TimeInterval] = [:]
        for (slot, entry) in entries {
            let cost = costModel.reloadCostSeconds(slot: slot,
                                                   modelID: entry.modelID,
                                                   footprint: entry.footprint,
                                                   deviceClass: deviceClass)
            if cost.isFinite { costs[slot] = cost }
        }
        return costs
    }

    /// [MODEL-WARDEN] Step 0 — report the app's actual footprint alongside
    /// the ledger's inferred one.
    ///
    /// Called at the moments the ledger changes shape (residency recorded, an
    /// eviction, a pressure level) rather than on a timer: a periodic sample
    /// would mostly report an idle app and would cost a `task_info` per
    /// tick, while the number that explains a kill is the one taken while
    /// the shape was changing.
    ///
    /// `ceilingBytes` is *derived* — `availableProcessMemoryBytes` is the
    /// headroom, so the ceiling is headroom + footprint. Reporting the
    /// derived value rather than an independent claim keeps the two readings
    /// consistent by construction; the point of the pair is that
    /// `phys_footprint` against the ledger's total is the *checkable* half.
    func sampleFootprint() {
        lock.lock()
        let resident = residentLiveBytesLocked()
        let transient = transientLiveBytesLocked()
        lock.unlock()
        let footprint = probe.physFootprintBytes
        guard footprint > 0 else { return }
        let ceiling = probe.availableProcessMemoryBytes + footprint
        // [MODEL-WARDEN] Step 3 — the same reading, kept. Two things read it:
        // `workingSetBytes(for:)` is the measured `W(t)` the class budget was
        // derived from, and `workingSetIsPressed` is what stops the cost
        // model from *lengthening* holds on a device whose non-model
        // footprint has already grown past the assumption. Recording here
        // rather than at a call site means the sample the events carry and
        // the sample the ordering uses are the same one.
        lock.lock()
        costModel.record(ModelFootprintCostSample(
            deviceClass: currentDeviceClassLocked(),
            physFootprintBytes: footprint,
            ceilingBytes: ceiling,
            residentLiveBytes: resident,
            transientLiveBytes: transient,
            at: clock()))
        lock.unlock()
        onEvent?(.footprintSample(
            physFootprintBytes: footprint,
            ceilingBytes: ceiling,
            residentLiveBytes: resident,
            transientLiveBytes: transient))
    }

    // MARK: - [MODEL-WARDEN] Step 3 — the cost model's surface

    /// Record one measured load. Load sites call this the moment the model
    /// lands, with the same `load_ms` they already put on the observability
    /// bus (`WhisperKitSpeechRecognizer` and `WhisperSpeechRecognizer` both
    /// measure it around their own construction).
    ///
    /// It is fire-and-forget by design: a load that succeeds and reports its
    /// cost a moment late must not fail, and the *next* eviction decision is
    /// the first thing that can use it. A reading that never arrives leaves
    /// the key on its documented prior, which is a state the ordering
    /// handles — see `ModelReloadPrior`.
    ///
    /// `slot`/`modelID` are the caller's own, not looked up: the caller
    /// knows which artifact it just built, and a re-derivation from the
    /// catalog here would be a second answer to a question that has one.
    func noteLoadCost(loadMs: Double, slot: ModelSlot, modelID: ModelID?) {
        lock.lock()
        costModel.record(loadMs: loadMs,
                         slot: slot,
                         modelID: modelID,
                         deviceClass: currentDeviceClassLocked(),
                         at: clock())
        lock.unlock()
    }

    /// Seconds to bring the slot's current resident back. `nil` when the
    /// slot is unregistered.
    ///
    /// The reader is the manager's own ordering, but it is public because
    /// the honest thing to show a household or a capture is the number the
    /// decision was made with, not a re-derivation — and the answer only
    /// exists under this lock.
    func reloadCostSeconds(for slot: ModelSlot) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[slot] else { return nil }
        return costModel.reloadCostSeconds(slot: slot,
                                           modelID: entry.modelID,
                                           footprint: entry.footprint,
                                           deviceClass: currentDeviceClassLocked())
    }

    /// What has been measured for one slot: sample count and percentiles.
    func measuredLoadCost(for slot: ModelSlot) -> LoadCost {
        lock.lock()
        defer { lock.unlock() }
        return costModel.cost(slot: slot,
                              modelID: entries[slot]?.modelID,
                              deviceClass: currentDeviceClassLocked())
    }

    /// The measured working set `W(t)` for the current class, or `nil`
    /// before any `footprintSample`. This is the number the class budget
    /// assumed was ~300 MB; a capture that shows otherwise is a capture
    /// saying the budget's premise moved.
    func measuredWorkingSetBytes() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return costModel.workingSetBytes(for: currentDeviceClassLocked())
    }

    // MARK: [MODEL-WARDEN] Step 3 — the class policy

    /// Whether this device may be **offered** `entry` at all, and if not, the
    /// reason to show. This is the check the Settings rows call.
    ///
    /// It lives on the ledger rather than in the view for the reason the
    /// whole file exists: the class comes from `currentDeviceClassLocked()`,
    /// i.e. the same probe and the same boundaries the admissions are made
    /// against. A view reading `ProcessInfo.processInfo.physicalMemory`
    /// would be answering about a different device than the one being
    /// budgeted, and would disagree with the ledger on exactly the phones
    /// where the answer matters.
    ///
    /// The warm STT is likewise read from the ledger's own registration —
    /// `.speechToText`'s `modelID`, which is the model it will actually load
    /// — rather than reconstructed by the caller from a preference. That
    /// matters on the STT's two backends: the ANE graph and the whisper.cpp
    /// context differ by 0.1 GB, which is enough to change a 3B's sentence
    /// on the standard class.
    ///
    /// **Advisory by construction: it refuses nothing.** The policy says what
    /// a class may be offered; enforcement stays where Step 2 put it (the
    /// `soloOverBudget` escape hatch for a preference already stored, then
    /// the ledger's own gate). Nothing here can make a resident model
    /// unloadable, which is the property that keeps a stored preference
    /// reachable no matter what the row says.
    ///
    /// `physicalMemoryBytes` is the probe's. `budgetOverrideBytes` is a test
    /// hook that pins the *class* only, so a test host whose RAM disagrees
    /// with the pinned class gets the probe's device in this answer — the
    /// truthful reading, since the catalog's `minDeviceRAMBytes` is a claim
    /// about the phone and not about the class.
    func availability(of entry: ModelCatalogEntry) -> ModelAvailability {
        lock.lock()
        let inputs = availabilityInputsLocked()
        lock.unlock()
        return inputs.policy.availability(of: entry,
                                          physicalMemoryBytes: inputs.physicalMemoryBytes,
                                          warmSTTLiveBytes: inputs.warmSTTLiveBytes)
    }

    /// [MODEL-WARDEN 2026-09-18] The three numbers `availability(of:)`
    /// answers with, handed to callers that must ask the policy *many*
    /// questions against one reading — `LanguageModelResolver`'s automatic
    /// pick walks a whole ladder, and re-deriving the class per rung would
    /// let a probe that moved mid-walk answer two questions about two
    /// devices.
    ///
    /// Exposed rather than re-derived by the caller for the reason the doc
    /// above gives: the class must be THIS ledger's, from the probe and the
    /// boundaries the admissions use, and the warm STT must be the ledger's
    /// own registration. It is the same triple either way — `availability(of:)`
    /// is now literally this struct applied to one entry — so a row and an
    /// automatic pick cannot drift apart.
    struct AvailabilityInputs {
        let policy: ModelBudgetPolicy
        let physicalMemoryBytes: UInt64
        let warmSTTLiveBytes: UInt64?
    }

    /// The current inputs, under the lock. Cheap (a probe read + one
    /// dictionary lookup) and side-effect free.
    var availabilityInputs: AvailabilityInputs {
        lock.lock()
        defer { lock.unlock() }
        return availabilityInputsLocked()
    }

    private func availabilityInputsLocked() -> AvailabilityInputs {
        let deviceClass = currentDeviceClassLocked()
        let warmSTTModelID = entries[.speechToText]?.modelID
        return AvailabilityInputs(
            policy: ModelBudgetPolicy.policy(for: deviceClass),
            physicalMemoryBytes: probe.physicalMemoryBytes,
            warmSTTLiveBytes: ModelBudgetPolicy.warmSTTLiveBytes(
                forSTTModelID: warmSTTModelID))
    }

    /// Whether the measured working set has outgrown what the class budget
    /// assumed for it. When true the cost model stops extending idle holds:
    /// the app, not the models, is what has grown, and holding models longer
    /// would make that worse rather than better.
    private func workingSetIsPressedLocked(
        for deviceClass: ModelLifecycleBudget.DeviceClass)
    -> Bool {
        guard let measured = costModel.workingSetBytes(for: deviceClass) else {
            return false
        }
        // The policy's own figure is the assumption being checked, and it is
        // per-class (0.30 GB on compact/standard, 0.40 GB on roomy) rather
        // than a constant here — the class is the thing that was sized.
        let assumed = ModelBudgetPolicy.policy(for: deviceClass).workingSetIdleBytes
        return measured > assumed
    }

    /// Whether a slot currently counts as resident. Test/observability seam.
    func isResident(_ slot: ModelSlot) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[slot]?.isResident ?? false
    }

    /// The footprint the manager is budgeting for a slot.
    func footprint(of slot: ModelSlot) -> ModelFootprint? {
        lock.lock()
        defer { lock.unlock() }
        return entries[slot]?.footprint
    }

    // MARK: Locked helpers

    private func currentDeviceClassLocked() -> ModelLifecycleBudget.DeviceClass {
        if budgetOverrideBytes != nil { return .standard }
        return ModelLifecycleBudget.deviceClass(
            physicalMemoryBytes: probe.physicalMemoryBytes)
    }

    // MARK: [CAMERA-BUDGET] The budgets in force

    /// The **class** budget: the device class's own promise, or the test pin.
    ///
    /// This is the bound the translation tier's escape hatch
    /// (`ReservationPurpose.mayEvictPastTheSessionBudget`) is judged against,
    /// and it is deliberately **not** lowered by the session profile: a
    /// profile that lowered it closed the hatch and refused the tier's own
    /// model `over_budget_alone` for the whole camera session (review finding
    /// on #99). The profile's job is done by `sessionBudgetLocked` below.
    private func classBudgetLocked(deviceClass: ModelLifecycleBudget.DeviceClass) -> UInt64 {
        budgetOverrideBytes ?? ModelLifecycleBudget.modelsBudgetBytes(for: deviceClass)
    }

    /// The class budget with an active session profile folded in, and the
    /// probe deliberately left out: what the snapshot reports as the class
    /// budget, and what the pressure responses squeeze to a fraction of.
    ///
    /// It exists as its own spelling so those two call sites cannot drift
    /// from each other — the shape the five copy-pasted
    /// `budgetOverrideBytes ?? sessionProfileOverrideBytes ?? …` chains used
    /// to invite.
    private func profileAdjustedClassBudgetLocked(
        deviceClass: ModelLifecycleBudget.DeviceClass) -> UInt64 {
        budgetOverrideBytes
            ?? sessionProfileBytesLocked()
            ?? ModelLifecycleBudget.modelsBudgetBytes(for: deviceClass)
    }

    /// The **session** budget: what a load whose bytes are purely additive to
    /// everyone else's is judged against right now.
    ///
    /// `budgetOverrideBytes` (tests) wins outright, so every test that pins the
    /// class keeps the arithmetic it was written against. Otherwise it is the
    /// live probe's reading — the number that tracks the real device — lowered
    /// by an active session profile and **never raised by it**: `min(profile,
    /// probeDerived)`. The profile used to short-circuit the probe, so a fixed
    /// 2.1 GB could sit ABOVE a probe reading that pressure had already pushed
    /// below it, re-admitting exactly the pressure-eviction the profile exists
    /// to prevent (review finding on #99).
    private func sessionBudgetLocked(deviceClass: ModelLifecycleBudget.DeviceClass,
                                     residentLiveBytes: UInt64) -> UInt64 {
        if let pinned = budgetOverrideBytes { return pinned }
        let probeDerived = ModelLifecycleBudget.effectiveBudgetBytes(
            deviceClass: deviceClass,
            availableBytes: probe.availableProcessMemoryBytes,
            residentLiveBytes: residentLiveBytes)
        guard let profileBytes = sessionProfileBytesLocked() else { return probeDerived }
        return min(profileBytes, probeDerived)
    }

    /// The active session profile's model budget, or `nil`.
    ///
    /// A lease whose owner has been deallocated, or that has outlived
    /// `ModelWardenConfig.sessionProfileTTLSeconds`, is dropped **here**: the
    /// read is the last place that can still see the whole fact, exactly where
    /// `pruneDeadOwnersLocked` sits for reservations. The drop is silent on
    /// this path (it is reached under the admission lock, where emitting would
    /// be a callback under a lock); `reapExpiredSessionProfile(now:)` is the
    /// reporting half, and the four public surfaces that can emit —
    /// `setSessionProfile`, `reserve`, `snapshot`, and the two pressure
    /// handlers — all call it before they read. This half stays because it is
    /// the correctness half: whatever a future caller forgets, the arithmetic
    /// cannot see a lease that no longer applies.
    private func sessionProfileBytesLocked() -> UInt64? {
        guard let lease = sessionProfileLease else { return nil }
        guard Self.expiryReason(for: lease,
                                now: clock(),
                                ttl: wardenConfig.sessionProfileTTLSeconds) == nil else {
            sessionProfileLease = nil
            return nil
        }
        return lease.budgetBytes
    }

    private func residentLiveBytesLocked(excluding excluded: ModelSlot? = nil) -> UInt64 {
        entries.filter { $0.key != excluded }
            .values.filter(\.isResident)
            .reduce(UInt64(0)) { $0 + $1.footprint.liveBytes }
    }

    /// Eviction order: **heavy models first, least-recently-used within
    /// that, then light models least-recently-used.**
    ///
    /// Plain LRU over all slots would be a mistake here. The budget is
    /// dominated by heavy models — one 3.4 GB brain outweighs every light
    /// model combined — so evicting an idle 140 MB encoder because it
    /// happened to be touched longest ago frees almost nothing while
    /// costing a CoreML specialization on the next turn. The corrector is
    /// worse still: it cannot be reloaded at all.
    ///
    /// Heavy-first is also the honest expression of the invariant. "STT and
    /// the 4B brain never co-reside" is a statement about heavy models;
    /// the light ones are expected to survive every eviction.
    private func lruEvictionOrderLocked(excluding excluded: ModelSlot?) -> [ModelSlot] {
        entries.compactMap { slot, entry -> (ModelSlot, Bool, Date, UInt64)? in
            guard entry.isResident, entry.evictable,
                  entry.pinCount == 0, slot != excluded,
                  entry.owner != nil else { return nil }
            return (slot, entry.footprint.isHeavy, entry.lastUse,
                    entry.footprint.liveBytes)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 && !rhs.1 }   // heavy before light
            if lhs.2 != rhs.2 { return lhs.2 < rhs.2 }     // least recent first
            return lhs.3 > rhs.3                           // bigger frees more
        }
        .map { $0.0 }
    }

    private func markNonResidentLocked(_ slot: ModelSlot) {
        guard var entry = entries[slot] else { return }
        entry.isResident = false
        entries[slot] = entry
    }

    /// A slot whose owner has been deallocated can never be released and
    /// must stop counting toward the budget — otherwise a dead recognizer
    /// permanently reserves 2 GB.
    ///
    /// `.processLifetime` rows are exempt: they have no owning object by
    /// construction (the corrector's lexicon is a `static let`), and they
    /// are exactly the bytes that never come back, so dropping them would
    /// make the ledger's total a lie in the one direction that matters.
    private func pruneDeadOwnersLocked() {
        for (slot, entry) in entries
        where entry.owner == nil
            && entry.footprint.releaseContract != .processLifetime {
            entries.removeValue(forKey: slot)
        }
    }

    /// Invoke the slot's release closure. Always outside the lock.
    private func performEviction(_ slot: ModelSlot, reason: EvictionReason) {
        lock.lock()
        let unload = entries[slot]?.unload
        lock.unlock()
        unload?()
        onEvent?(.evicted(slot: slot, reason: reason))
    }

    // MARK: - [MODEL-WARDEN] Step 3 — what is built, and what is still a seam
    //
    // ### Built in Step 3
    //
    // 1. **The cost model** (`ModelCostModel`). The ladder is still ordinal
    //    and still the victim order's first key; what sits behind it is now
    //    `idleSeconds × liveBytes ÷ reloadCostSeconds` instead of the pair
    //    "(least recent, bigger)". The readings come from the app's own
    //    `load_ms` (`noteLoadCost`) and the ledger's `footprintSample`
    //    (`sampleFootprint`), both of which existed before this step — Step
    //    3 gave them a reader.
    // 2. **The derived idle threshold.** `evictIdle` uses
    //    `max(idleEvictionSeconds, reloadCost / idleEvictionPenalty)` per
    //    resident, so a measured reload longer than the configured base
    //    holds a resident through it. Nothing shipped moves: the ANE prior
    //    (77 s) and the brain priors are all under 120 s.
    // 3. **The class policy** (`ModelBudgetPolicy`) — what may be *chosen*,
    //    as distinct from what may be *resident*. The two are deliberately
    //    different questions and this class answers only the first: the
    //    ledger admits, the policy offers. It acts in two places, both of
    //    them *choice* surfaces: `availability(of:)` here (the seam the
    //    Settings rows and picker options ask, so the answer comes from the
    //    class this ledger admits against rather than from a second guess
    //    about the device) and the Settings screen itself, where an
    //    unavailable model is shown, marked, and not selectable, and its
    //    download is not offered.
    //
    //    **The gap this note used to leave open — what "Automatic" runs —
    //    is closed (2026-09-18, [MODEL-WARDEN] policy picks).** The
    //    catalog's language defaults stay device-blind
    //    (`ModelCatalog.languageDefaultPicks[.llamaBase]["ne"]` is still the
    //    4B), but the *resolution* now consults this same policy:
    //    `LanguageModelResolver.resolvedAutomaticPick` takes the language
    //    default as its first rung and steps down the curated ladder to the
    //    largest artifact that fits beside the warm STT, so a Nepali 6 GB
    //    phone resolves to the 1.7B. It asks the policy through
    //    `availabilityInputs` above — this ledger's class and this ledger's
    //    registered STT — which is what keeps the ledger and the pick
    //    answering as one.
    //
    //    Two things deliberately did NOT move with it: the ledger's own
    //    behaviour (this is a *choice* seam — nothing here admits or refuses
    //    differently) and an EXPLICIT stored preference, which is still
    //    served unchanged through the `soloOverBudget` escape hatch, the
    //    path that exists so a resident is never unloadable. The gate is on
    //    the automatic path only. §7 Q1 (a per-class accuracy-for-latency
    //    trade) remains open for the picker's ordering; it is no longer a
    //    precondition for automatic selection.
    // 4. **§7.4's ANE default**, as arithmetic rather than as a special
    //    case. See `loadEvictionOrderLocked`. "Evict the ANE STT last among
    //    victims of equal residency value" is what the 77 s denominator
    //    *produces*; "never for an LRU sweep" is honoured in the ordering
    //    (the sweep does not consult the cost model's order) while the
    //    sweep's own 120 s threshold stays where the shipped tests pin it.
    //
    // ### Still a seam
    //
    // 5. **Asynchronous acks.** `ModelResident.releaseForWarden` is
    //    synchronous by construction, which is what makes it callable from
    //    the reservation's fail-fast path. An owner whose drop is genuinely
    //    deferred (a decode that must reach a safe point first) cannot use
    //    it, and today says `.refused(.cannotReleaseNow)` instead. Making
    //    the ack awaitable means a two-phase reservation whose `reserve`
    //    suspends — a different API shape, and
    //    `ModelWardenConfig.unloadAckDeadlineSeconds` is already the bound
    //    it would be judged against. **What the upgrade has to preserve**,
    //    in the order it will discover them: (a) `reserve` is called from
    //    synchronous paths today (`prepareLoad` on the boot warm, the
    //    recognizers' load sites), so an `async` overload cannot replace the
    //    existing one — it has to be a second entry point; (b) the refusal
    //    grace (`refusalGraceUntil`) becomes a *real* deadline rather than a
    //    remembered opinion, which means the slot must be re-askable when it
    //    expires rather than on the next load's walk; (c) the cost model
    //    gains nothing from it — reload cost is measured from `load_ms`,
    //    not from how the ack arrived.
    //
    // 6. **Owner-side conformance.** The tier's generator registers a
    //    `ModelResident`; the recognizers do not yet, so their residency is
    //    still taken through the Step 1 path. Adding it is a per-owner
    //    change with its own test surface (whisper.cpp's perAttemptContext
    //    refusal is the interesting one) and it does not change any
    //    arithmetic here.
    //
    // 7. **The camera session's reduced budget.** `ModelBudgetPolicy`
    //    carries `workingSetCameraBytes` and
    //    `sessionModelBudgetBytes(session: .cameraLive)` computes the number
    //    (§3.3), and nothing calls it: lowering the model budget for the
    //    duration of a live-translate session is a `LiveTranslateConfig`
    //    change and Step 3's non-goals exclude the camera pipeline. The
    //    arithmetic is here so the wiring is a call and not a derivation.
    //    Until it is wired, a camera session holds a brain the class budget
    //    has not reserved room for — which the ledger's reservation path
    //    still bounds at load time.
}
