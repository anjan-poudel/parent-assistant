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
}

/// Production probe: a pass-through to `MemoryProbe`.
struct SystemMemoryProbe: MemoryProbing {
    var physicalMemoryBytes: UInt64 { MemoryProbe.physicalMemoryBytes }
    var availableProcessMemoryBytes: UInt64 {
        MemoryProbe.availableProcessMemoryBytes
    }
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
    /// Unused past the idle threshold.
    case idle
    /// Caller asked (model swap, explicit teardown).
    case explicit
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
}

/// A point-in-time view of the ledger. For tests and diagnostics.
struct ModelLifecycleSnapshot: Equatable {
    let deviceClass: ModelLifecycleBudget.DeviceClass
    let budgetBytes: UInt64
    let effectiveBudgetBytes: UInt64
    let residentLiveBytes: UInt64
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

    private let probe: MemoryProbing
    private let clock: () -> Date
    let idleEvictionSeconds: TimeInterval

    /// Test hook: pins the class budget so arithmetic is not at the mercy of
    /// the host machine's RAM. `nil` in production.
    private let budgetOverrideBytes: UInt64?

    private let lock = NSLock()
    private var entries: [ModelSlot: Entry] = [:]
    private var idleTimer: DispatchSourceTimer?

    /// Bridged to the observability bus by the coordinator. Called outside
    /// the lock, on the caller's queue.
    var onEvent: ((ModelLifecycleEvent) -> Void)?

    init(probe: MemoryProbing = SystemMemoryProbe(),
         clock: @escaping () -> Date = { Date() },
         idleEvictionSeconds: TimeInterval = ModelLifecycleManager.defaultIdleEvictionSeconds,
         budgetOverrideBytes: UInt64? = nil) {
        self.probe = probe
        self.clock = clock
        self.idleEvictionSeconds = idleEvictionSeconds
        self.budgetOverrideBytes = budgetOverrideBytes
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
        let incoming = ModelLifecycleInventory.footprint(for: slot, modelID: modelID)

        // Phase 1 — decide under the lock, touching no owner code.
        var victims: [ModelSlot] = []
        var denied: LoadDenialReason?
        var soloOverBudget = false
        var budgetUsed: UInt64 = 0

        lock.lock()
        pruneDeadOwnersLocked()
        if entries[slot] == nil {
            denied = .unregisteredSlot
        } else {
            let deviceClass = currentDeviceClassLocked()
            // Exclude the incoming slot's OWN current residency: the load
            // replaces whatever the slot held, so counting both would
            // double-book the same pipeline position and evict an innocent
            // bystander. (The recognizers and the interpreter both short-
            // circuit a load when they already hold the same model, so by
            // the time we are asked the slot is either empty or stale.)
            var residentLive = residentLiveBytesLocked(excluding: slot)
            var budget = budgetOverrideBytes
                ?? ModelLifecycleBudget.effectiveBudgetBytes(
                    deviceClass: deviceClass,
                    availableBytes: probe.availableProcessMemoryBytes,
                    residentLiveBytes: residentLive)

            let victimOrder = lruEvictionOrderLocked(excluding: slot)
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
            where residentLive + incoming.liveBytes > budget {
                victims.append(victim)
                residentLive -= entries[victim]?.footprint.liveBytes ?? 0
                // Marking non-resident here (rather than after the unload)
                // keeps the arithmetic honest even though the owner's free
                // may land later, and keeps a second concurrent gate from
                // evicting the same slot twice.
                markNonResidentLocked(victim)
            }

            if residentLive + incoming.liveBytes > budget {
                if incoming.liveBytes > budget {
                    // Over budget on its own. Nothing we can evict changes
                    // that, and refusing would make the app's own default
                    // brain unloadable — admit it and announce the fact.
                    soloOverBudget = true
                } else {
                    // It fits alone, but unevictable bytes are in the way:
                    // a resident is pinned (an inference is in flight) or
                    // is not idle-evictable. Admitting here would cross the
                    // budget silently, which is the one thing this whole
                    // mechanism exists to prevent — so refuse instead.
                    denied = .budgetExhausted
                }
            }
            budgetUsed = budget
        }
        lock.unlock()

        // Phase 2 — release owners outside the lock.
        for victim in victims {
            performEviction(victim, reason: .budget)
        }

        if let denied {
            onEvent?(.denied(slot: slot, reason: denied))
            return .denied(denied)
        }

        // Phase 3 — re-probe after eviction. Eviction is what makes room,
        // so the pre-eviction reading is not the one to judge by.
        let availableNow = probe.availableProcessMemoryBytes
        let unmanagedReserve = slot == .speechToText
            && !ModelLifecycleInventory.isWhisperKitModel(modelID)
            ? ModelLifecycleInventory.whisperCPPWedgedReserveBytes : 0
        if incoming.hardBytes + unmanagedReserve > availableNow {
            onEvent?(.denied(slot: slot, reason: .insufficientHeadroom))
            return .denied(.insufficientHeadroom)
        }

        if soloOverBudget {
            onEvent?(.soloOverBudget(slot: slot,
                                     liveBytes: incoming.liveBytes,
                                     budgetBytes: budgetUsed))
        }
        onEvent?(.admitted(slot: slot, liveBytes: incoming.liveBytes,
                           evicted: victims))
        return .allowed(evicted: victims)
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
        defer { lock.unlock() }
        guard var entry = entries[slot] else { return }
        if let owner, !isOwned(entry, by: owner) { return }
        let now = clock()
        entry.isResident = true
        entry.loadedAt = now
        entry.lastUse = now
        entries[slot] = entry
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
        return victims
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
            resident: entries.filter { $0.value.isResident }
                .map { $0.key }.sorted { $0.rawValue < $1.rawValue },
            pinned: entries.filter { $0.value.pinCount > 0 }
                .map { $0.key }.sorted { $0.rawValue < $1.rawValue })
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
