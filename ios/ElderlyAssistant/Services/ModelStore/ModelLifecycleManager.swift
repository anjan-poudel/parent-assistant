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

/// Everything the manager did, in order. The coordinator can bridge these to
/// the observability bus; tests assert on them directly.
enum ModelLifecycleEvent: Equatable {
    case admitted(slot: ModelSlot, liveBytes: UInt64, evicted: [ModelSlot])
    case denied(slot: ModelSlot, reason: LoadDenialReason)
    case evicted(slot: ModelSlot, reason: EvictionReason)
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
        weak var owner: AnyObject?
        let unload: () -> Void
        let evictable: Bool
        var isResident: Bool
        var loadedAt: Date
        var lastUse: Date
        var pinCount: Int
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

    private let lock = NSLock()
    private var entries: [ModelSlot: Entry] = [:]
    private var idleTimer: DispatchSourceTimer?
    /// [MODEL-WARDEN] Step 1 — the in-flight half of the ledger: reservations
    /// granted and not yet committed or abandoned. This is `T(t)` in the
    /// proposal's `peak_footprint = M + T + W`.
    private var reservations: [UUID: ModelReservation] = [:]
    private var reservationOwners: [UUID: WeakOwner] = [:]
    /// The dispatch memory-pressure source (`.warning` / `.critical`), which
    /// the proposal records as "the closer-to-the-kernel signal" and which
    /// the tree did not use anywhere before Step 0.
    private var pressureSource: DispatchSourceMemoryPressure?

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
                  unload: @escaping () -> Void) {
        let footprint = ModelLifecycleInventory.footprint(for: slot, modelID: modelID)
        lock.lock()
        let now = clock()
        if var existing = entries[slot] {
            existing = Entry(footprint: footprint,
                             owner: owner,
                             unload: unload,
                             evictable: evictable,
                             isResident: existing.isResident,
                             loadedAt: existing.loadedAt,
                             lastUse: existing.lastUse,
                             pinCount: existing.pinCount)
            entries[slot] = existing
        } else {
            entries[slot] = Entry(footprint: footprint,
                                  owner: owner,
                                  unload: unload,
                                  evictable: evictable,
                                  isResident: false,
                                  loadedAt: now,
                                  lastUse: now,
                                  pinCount: 0)
        }
        lock.unlock()
    }

    /// Convenience for slots whose release path is a plain method.
    func register(slot: ModelSlot,
                  modelID: ModelID?,
                  owner: AnyObject?,
                  evictable: Bool = true,
                  release: @escaping (AnyObject) -> Void) {
        register(slot: slot, modelID: modelID, owner: owner,
                 evictable: evictable) { [weak owner] in
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
        case .budgetExhausted, .alreadyReserved, .loadInFlight:
            // Something is holding the bytes or the queue. Both are "retry
            // after the in-flight work settles", which is what
            // `budgetExhausted` already means to every caller.
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
    /// Step 2's priority ladder slots in at step 2 (victim selection) and
    /// step 4 (preemption); Step 3's cost model reads the events. Neither
    /// is built here.
    func reserve(_ request: ModelLoadRequest) -> Result<ModelReservation, ReservationDenial> {
        reserveInternal(request, emittingEvents: true)
    }

    private func reserveInternal(_ request: ModelLoadRequest,
                                 emittingEvents: Bool)
    -> Result<ModelReservation, ReservationDenial> {
        let incoming = ModelLifecycleInventory.footprint(for: request.slot,
                                                         modelID: request.modelID)
        let config = wardenConfig
        let now = clock()

        var victims: [ModelSlot] = []
        var denial: ReservationDenial?
        var soloOverBudget = false
        var budgetUsed: UInt64 = 0
        var reaped: [(reservation: ModelReservation,
                      reason: ReservationAbandonReason)] = []

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
        } else {
            let deviceClass = currentDeviceClassLocked()
            // See `ModelLoadRequest.replacesSlotContents`: a replacing load
            // excludes the slot's own residency (one position being
            // refilled); a peer load does not (the bytes are additive).
            var residentLive = request.replacesSlotContents
                ? residentLiveBytesLocked(excluding: request.slot)
                : residentLiveBytesLocked()
            let transientLive = transientLiveBytesLocked()
            let budget = budgetOverrideBytes
                ?? ModelLifecycleBudget.effectiveBudgetBytes(
                    deviceClass: deviceClass,
                    availableBytes: probe.availableProcessMemoryBytes,
                    residentLiveBytes: residentLive)

            let victimOrder = lruEvictionOrderLocked(
                excluding: request.replacesSlotContents ? request.slot : nil)
            let heavyVictims = victimOrder.filter {
                entries[$0]?.footprint.isHeavy ?? false
            }
            // Light models are only candidates when evicting them can
            // actually close the gap. If the incoming model is over budget
            // on its own, nothing light can help, and taking the encoder
            // would cost a CoreML specialization for zero bytes — see the
            // `soloOverBudget` branch below.
            let lightVictims = incoming.liveBytes > budget
                ? []
                : victimOrder.filter { !(entries[$0]?.footprint.isHeavy ?? false) }

            for victim in heavyVictims + lightVictims
            where residentLive + transientLive + incoming.liveBytes > budget {
                victims.append(victim)
                residentLive -= entries[victim]?.footprint.liveBytes ?? 0
                // Marking non-resident here (rather than after the unload)
                // keeps the arithmetic honest even though the owner's free
                // may land later, and keeps a second concurrent gate from
                // evicting the same slot twice.
                markNonResidentLocked(victim)
            }

            if residentLive + transientLive + incoming.liveBytes > budget {
                if incoming.liveBytes > budget {
                    if request.replacesSlotContents {
                        // Over budget on its own. Nothing we can evict
                        // changes that, and refusing would make the app's
                        // own default brain unloadable — admit it and
                        // announce the fact.
                        soloOverBudget = true
                    } else {
                        // A PEER load over budget on its own has no such
                        // escape hatch to invoke: it is a second copy of
                        // something the device already cannot hold beside
                        // its neighbours, and the user did not ask for it.
                        denial = .overBudgetAlone(liveBytes: incoming.liveBytes,
                                                  budgetBytes: budget)
                    }
                } else {
                    // It fits alone, but unevictable bytes are in the way:
                    // a resident is pinned (an inference is in flight) or
                    // is not idle-evictable. Admitting here would cross the
                    // budget silently, which is the one thing this whole
                    // mechanism exists to prevent — so refuse instead.
                    denial = .budgetExhausted(by: blockerLocked(victims: victims,
                                                                slot: request.slot))
                }
            }
            budgetUsed = budget
        }
        lock.unlock()

        // Emissions and evictions both happen outside the lock.
        if emittingEvents {
            for entry in reaped {
                onEvent?(.reservationAbandoned(slot: entry.reservation.slot,
                                               reason: entry.reason))
            }
        }
        for victim in victims { performEviction(victim, reason: .budget) }

        if let denial {
            if emittingEvents {
                onEvent?(.reservationDenied(slot: request.slot,
                                            reason: denial,
                                            purpose: request.purpose))
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
            budgetBytes: budgetUsed)

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
    /// older than `idleEvictionSeconds`. The clock is injected, so tests
    /// drive this directly instead of waiting.
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
        let idle = entries.compactMap { slot, entry -> ModelSlot? in
            guard entry.isResident, entry.evictable,
                  entry.pinCount == 0, entry.footprint.isHeavy else { return nil }
            let unusedFor = reference.timeIntervalSince(entry.lastUse)
            return unusedFor >= idleEvictionSeconds ? slot : nil
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
    @discardableResult
    func handleMemoryPressure() -> [ModelSlot] {
        lock.lock()
        pruneDeadOwnersLocked()
        let fullBudget = budgetOverrideBytes
            ?? ModelLifecycleBudget.modelsBudgetBytes(for: currentDeviceClassLocked())
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
    @discardableResult
    func handleMemoryPressure(level: MemoryPressureLevel) -> [ModelSlot] {
        switch level {
        case .normal:
            return []
        case .warning:
            return handleMemoryPressure()
        case .critical:
            return handleCriticalMemoryPressure()
        }
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
        let budget = budgetOverrideBytes
            ?? ModelLifecycleBudget.modelsBudgetBytes(for: currentDeviceClassLocked())
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
        lock.lock()
        defer { lock.unlock() }
        pruneDeadOwnersLocked()
        let deviceClass = currentDeviceClassLocked()
        let residentLive = residentLiveBytesLocked()
        let budget = budgetOverrideBytes
            ?? ModelLifecycleBudget.effectiveBudgetBytes(
                deviceClass: deviceClass,
                availableBytes: probe.availableProcessMemoryBytes,
                residentLiveBytes: residentLive)
        return ModelLifecycleSnapshot(
            deviceClass: deviceClass,
            budgetBytes: budgetOverrideBytes
                ?? ModelLifecycleBudget.modelsBudgetBytes(for: deviceClass),
            effectiveBudgetBytes: budget,
            residentLiveBytes: residentLive,
            transientLiveBytes: transientLiveBytesLocked(),
            inFlight: reservations.values.sorted { $0.reservedAt < $1.reservedAt },
            physFootprintBytes: probe.physFootprintBytes,
            resident: entries.filter { $0.value.isResident }
                .map { $0.key }.sorted { $0.rawValue < $1.rawValue },
            pinned: entries.filter { $0.value.pinCount > 0 }
                .map { $0.key }.sorted { $0.rawValue < $1.rawValue })
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
        onEvent?(.footprintSample(
            physFootprintBytes: footprint,
            ceilingBytes: probe.availableProcessMemoryBytes + footprint,
            residentLiveBytes: resident,
            transientLiveBytes: transient))
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
}
