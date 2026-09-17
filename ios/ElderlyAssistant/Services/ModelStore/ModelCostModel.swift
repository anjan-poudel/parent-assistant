import Foundation

// MARK: - [MODEL-WARDEN] Step 3 — the measured cost model
//
// Steps 0–2 made the warden's decisions **ordinal**: the ladder says which
// resident is less important, `loadEvictionOrderLocked` sorts by (ladder,
// heavy, LRU, bigger), and the idle sweep uses one fixed 120 s for every
// slot. None of that is arithmetic, and the proposal's §5.5 rests on one
// asymmetry an ordinal order cannot express:
//
//   The ANE STT is **1.0 GB of non-pageable weights** — the model whose
//   bytes the warden most wants back under pressure — and it is the one
//   whose reload costs **77 s** on a device (135 s after a failed ANE
//   compile). "Evict the least recently used heavy model" will happily
//   spend 77 s of a household's next turn to free 1 GB that the kernel
//   would then hand straight back to us on the reload.
//
// This type turns that into numbers. It is fed by readings the app already
// produces — `model_loaded` carries `load_ms` (`WhisperKitSpeechRecognizer`
// and `WhisperSpeechRecognizer` both measure it), and the ledger's own
// `footprintSample` carries the kernel's `phys_footprint` next to the
// ceiling — and it answers the two questions the ordering and the idle
// sweep need:
//
//   1. `reloadCostSeconds(slot:modelID:deviceClass:)` — how long bringing
//      this resident back costs, the **p95 of what has been measured** and
//      the documented prior below until there is a measurement.
//   2. `evictionPressure(idleSeconds:freedBytes:reloadCostSeconds:)` — the
//      single scalar the victim order sorts on: bytes reclaimable per
//      second of reload pain, weighted by how long the bytes have gone
//      unused. The ANE STT's 77 s is what puts it **last among victims of
//      equal residency value**, which is the proposal's §7.4 default on
//      ANE eviction expressed as arithmetic instead of as a special case.
//
// Everything here is a value type mutated under `ModelLifecycleManager`'s
// own lock: the manager is the only writer, and a caller that wants to read
// a cost asks the manager (`reloadCostSeconds(for:)`), never a copy that
// could drift from the one the decisions were made with.

/// What one `(slot, modelID, deviceClass)` costs to bring back, as measured.
///
/// `nil` percentiles and `sampleCount == 0` mean **not measured yet** — the
/// honest value, and the one the prior answers for. It is deliberately not
/// zero: a fake that reported "a reload is free" would make the eviction
/// order prefer the one resident whose reload the product cannot afford.
struct LoadCost: Equatable {
    let sampleCount: Int
    let p50Ms: Double?
    let p95Ms: Double?

    /// Whether any real `load_ms` has been recorded for this key. The
    /// distinction the field capture needs: a decision made on the prior and
    /// a decision made on device numbers look identical in the arithmetic
    /// and very different in a report.
    var isMeasured: Bool { sampleCount > 0 }

    static let unmeasured = LoadCost(sampleCount: 0, p50Ms: nil, p95Ms: nil)

    /// The p95 in seconds, or `nil` when nothing has been measured.
    var p95Seconds: Double? { p95Ms.map { $0 / 1000 } }

    var p50Seconds: Double? { p50Ms.map { $0 / 1000 } }
}

/// One `load_ms` reading, as a load site reports it.
struct ModelLoadCostSample: Equatable {
    let slot: ModelSlot
    let modelID: ModelID?
    let deviceClass: ModelLifecycleBudget.DeviceClass
    let loadMs: Double
    let at: Date
}

/// One `footprintSample` reading, from the ledger's own stream.
///
/// The cost model wants the *derived* working set `W(t)` rather than the
/// three raw numbers: `phys_footprint` is the kernel's total for the
/// process, and the ledger's resident + transient totals are the part that
/// is the warden's own doing. What is left is everything else — UIKit,
/// the audio session, camera/Vision, the Swift runtime — and it is the
/// quantity `model-lifecycle.md` assumed was ~300 MB when it derived the
/// 3.2 GB budget. A capture that shows `W` is not ~300 MB is a capture
/// saying the budget's premise moved, and it is the one signal that should
/// make the warden *stop* lengthening holds.
struct ModelFootprintCostSample: Equatable {
    let deviceClass: ModelLifecycleBudget.DeviceClass
    let physFootprintBytes: UInt64
    let ceilingBytes: UInt64
    let residentLiveBytes: UInt64
    let transientLiveBytes: UInt64
    let at: Date

    /// `W(t)`: the bytes the ledger cannot account for. Saturating —
    /// a probe that reads low must never trap or fabricate a negative
    /// working set.
    var workingSetBytes: UInt64 {
        let accounted = residentLiveBytes &+ transientLiveBytes
        return physFootprintBytes > accounted ? physFootprintBytes - accounted : 0
    }
}

/// The warden's **prior** for a resident nobody has measured yet.
///
/// Every number below is quoted from the proposal's §5.5 table (itself
/// derived from evidence already in the tree — the ANE figure is the
/// device measurement `WhisperPostTurnPolicy`'s header records, the llama
/// figure is the "full file page-in" the translate config's 30 s → 5 s
/// retune was reasoned about). A prior is a *starting* value: the moment a
/// real `load_ms` lands for the key, `ModelCostModel` stops answering with
/// these. They exist so the first launch on a fresh install still orders
/// its victims by cost instead of by nothing.
enum ModelReloadPrior {

    /// The ANE STT's cold load, including CoreML specialization —
    /// **77 s**, device evidence 2026-09-16 (the "क्यामेरा खोल" turn: a
    /// 72 s inter-turn gap resolved by a 77 s cold load).
    static let aneSpeechToTextSeconds: Double = 77

    /// The same load after `MILCompilerForANE error: failed to compile ANE
    /// model` — **135 s**. Recorded because the failure mode is a *reload*
    /// cost the prior would otherwise understate by 75 %.
    static let aneSpeechToTextRecompileSeconds: Double = 135

    /// whisper.cpp's per-attempt context. Pageable weights and a context
    /// built per utterance: cheap to lose, and it is lost on purpose after
    /// every attempt.
    static let whisperCPPSeconds: Double = 2

    /// A GGUF brain. The cost is a file page-in, so it scales with the
    /// artifact: the translate config calls per-batch reloads of the 4B
    /// "the CPU burn the watchdog kills for", and it is ~2.5 s per GB.
    static let brainSecondsPerGB: Double = 2.5

    /// Floor for a small brain, so a 0.5 GB model is not treated as free.
    static let brainFloorSeconds: Double = 1.5

    /// The Piper voices: ~21–24 MB per voice and a sherpa VITS session.
    /// Cheap in bytes *and* in time — but it is also the load that
    /// segfaults off-main on the x86_64 simulator (crash 204647), which is
    /// why it is a real cost and not zero.
    static let ttsVoiceSeconds: Double = 0.4

    /// The CoreML intent encoder: fast to load, non-pageable once resident,
    /// so its reload is cheap in seconds and its *residency* is the
    /// expensive half. That asymmetry is exactly why the cost model orders
    /// on reload cost and the class budget orders on bytes.
    static let intentEncoderSeconds: Double = 0.3

    /// No release path exists, so there is no "reload" to price: these
    /// residents must never be chosen for their reload cost's sake, and
    /// `evictionPressure` returns 0 for them.
    static let noReleasePathSeconds: Double = .infinity

    /// The prior for a slot/model pair, by the slot's role and the model's
    /// own size. `footprint` supplies the GB the brain arithmetic needs.
    static func seconds(slot: ModelSlot,
                        modelID: ModelID?,
                        footprint: ModelFootprint) -> Double {
        switch slot {
        case .speechToText:
            return ModelLifecycleInventory.isWhisperKitModel(modelID)
                ? aneSpeechToTextSeconds
                : whisperCPPSeconds
        case .brain, .translateBrain, .intentBrain:
            let gigabytes = Double(footprint.weightsBytes) / 1_000_000_000
            return max(brainFloorSeconds, gigabytes * brainSecondsPerGB)
        case .ttsVoices:
            return ttsVoiceSeconds
        case .intentEncoder:
            return intentEncoderSeconds
        case .sttCorrector, .wakeWord, .vad:
            return noReleasePathSeconds
        }
    }
}

/// The measured cost model. See the file header for what it is for.
struct ModelCostModel {

    /// Readings kept per key. Eight is enough for a stable p95 on a metric
    /// that moves with thermal state and ANE cache warmth, and it is
    /// bounded: the warden must not grow a history that outlives the
    /// residents it describes.
    static let maxSamplesPerKey = 8

    /// Readings kept for the footprint stream. Smaller still — `W(t)` is a
    /// slow-moving quantity and the only question asked of it is "is the
    /// app's own working set still inside what the budget assumed".
    static let maxFootprintSamples = 8

    /// A reload that costs "nothing" must still cost *something*, or the
    /// ordering divides by zero and the resident with the cheapest reload
    /// is evicted forever. A quarter second is below every load the app
    /// performs and above the arithmetic's need for a non-zero divisor.
    static let minimumReloadCostSeconds: Double = 0.25

    private struct Key: Hashable {
        let slot: ModelSlot
        let modelID: ModelID?
        let deviceClass: ModelLifecycleBudget.DeviceClass
    }

    private var samples: [Key: [Double]] = [:]
    private var footprints: [ModelLifecycleBudget.DeviceClass:
                             [ModelFootprintCostSample]] = [:]
    private(set) var lastSampleAt: Date?

    // MARK: Recording

    /// Record one measured load. `loadMs` is what every load site already
    /// measures; the manager forwards it here the moment the model lands.
    ///
    /// A non-positive or non-finite reading is dropped rather than stored:
    /// `CFAbsoluteTimeGetCurrent` differences are wall-clock and a clock
    /// step can produce one, and a single garbage sample would move a p95
    /// computed over eight.
    mutating func record(loadMs: Double,
                         slot: ModelSlot,
                         modelID: ModelID?,
                         deviceClass: ModelLifecycleBudget.DeviceClass,
                         at: Date) {
        guard loadMs.isFinite, loadMs > 0 else { return }
        let key = Key(slot: slot, modelID: modelID, deviceClass: deviceClass)
        var bucket = samples[key] ?? []
        bucket.append(loadMs)
        if bucket.count > Self.maxSamplesPerKey {
            bucket.removeFirst(bucket.count - Self.maxSamplesPerKey)
        }
        samples[key] = bucket
        lastSampleAt = at
    }

    /// Record one ledger footprint sample. See `ModelFootprintCostSample`
    /// for why the model wants the derived working set and not the raw
    /// kernel numbers.
    mutating func record(_ sample: ModelFootprintCostSample) {
        var bucket = footprints[sample.deviceClass] ?? []
        bucket.append(sample)
        if bucket.count > Self.maxFootprintSamples {
            bucket.removeFirst(bucket.count - Self.maxFootprintSamples)
        }
        footprints[sample.deviceClass] = bucket
    }

    // MARK: Reading

    /// What has been measured for this key. `.unmeasured` until a real
    /// `load_ms` arrives.
    func cost(slot: ModelSlot,
              modelID: ModelID?,
              deviceClass: ModelLifecycleBudget.DeviceClass) -> LoadCost {
        let key = Key(slot: slot, modelID: modelID, deviceClass: deviceClass)
        guard let bucket = samples[key], !bucket.isEmpty else { return .unmeasured }
        let sorted = bucket.sorted()
        return LoadCost(sampleCount: bucket.count,
                        p50Ms: Self.percentile(sorted, 0.50),
                        p95Ms: Self.percentile(sorted, 0.95))
    }

    /// The cost of losing a resident, in seconds — **the quantity the
    /// eviction order sorts on.**
    ///
    /// Measured p95 when the key has one (the honest number: a reload's
    /// *planning* value is its tail, not its median, because the reload is
    /// what a household waits through), the documented prior otherwise.
    /// Floored at `minimumReloadCostSeconds` so no resident is ever priced
    /// as free.
    func reloadCostSeconds(slot: ModelSlot,
                           modelID: ModelID?,
                           footprint: ModelFootprint,
                           deviceClass: ModelLifecycleBudget.DeviceClass) -> Double {
        let measured = cost(slot: slot, modelID: modelID,
                            deviceClass: deviceClass).p95Seconds
        let prior = ModelReloadPrior.seconds(slot: slot,
                                             modelID: modelID,
                                             footprint: footprint)
        guard let value = measured ?? (prior.isFinite ? prior : nil) else {
            // No release path: `evictionPressure` treats this as "never a
            // victim", and the floor is deliberately NOT applied — pricing
            // an unloadable slot as cheap is the one error that matters.
            return ModelReloadPrior.noReleasePathSeconds
        }
        return max(Self.minimumReloadCostSeconds, value)
    }

    /// **The cost-aware eviction score — highest goes first.**
    ///
    ///     pressure = idleSeconds × freedBytes
    ///                ──────────────────────
    ///                reloadCostSeconds
    ///
    /// Bytes reclaimable per second of reload pain, weighted by how long
    /// the bytes have gone unused. Each term is doing one job:
    ///
    ///  - `idleSeconds` — LRU's vote. A resident untouched for ten minutes
    ///    is worth less than one touched a second ago.
    ///  - `freedBytes` — Step 1's "bigger frees more". Taking 3.4 GB back
    ///    is worth more than taking 140 MB, at equal staleness.
    ///  - `reloadCostSeconds` — **the ANE term.** A resident whose reload
    ///    costs 77 s has to be dramatically staler and larger than a
    ///    cheaper rival before the warden prefers it as a victim. That is
    ///    §7.4's accepted default ("only under pressure or an explicit
    ///    swap; never for an LRU sweep") stated as a number rather than as
    ///    a special case in the comparator.
    ///
    /// A resident with no release path scores 0 and is last by
    /// construction; it cannot be a victim anyway (`evictable == false`),
    /// and making the arithmetic agree with the flag means a future change
    /// to one of them cannot silently disagree with the other.
    static func evictionPressure(idleSeconds: Double,
                                 freedBytes: UInt64,
                                 reloadCostSeconds: Double) -> Double {
        guard reloadCostSeconds.isFinite, reloadCostSeconds > 0 else { return 0 }
        let idle = max(0, idleSeconds)
        return idle * Double(freedBytes) / reloadCostSeconds
    }

    /// The same arithmetic as the victim order, for one resident: the
    /// manager supplies the idle age and the bytes.
    func evictionPressure(slot: ModelSlot,
                          modelID: ModelID?,
                          footprint: ModelFootprint,
                          deviceClass: ModelLifecycleBudget.DeviceClass,
                          idleSeconds: Double) -> Double {
        Self.evictionPressure(
            idleSeconds: idleSeconds,
            freedBytes: footprint.liveBytes,
            reloadCostSeconds: reloadCostSeconds(slot: slot,
                                                 modelID: modelID,
                                                 footprint: footprint,
                                                 deviceClass: deviceClass))
    }

    // MARK: The hold arithmetic

    /// The proposal's own inequality, §4.4 D2:
    ///
    ///     hold if  expectedIdleGapSeconds × idleEvictionPenalty
    ///              <  reloadCostSeconds
    ///
    /// Rearranged, it reads as a threshold: a resident is worth holding for
    /// `reloadCostSeconds / idleEvictionPenalty` seconds of idleness before
    /// releasing it is the cheaper answer.
    static func holdSeconds(reloadCostSeconds: Double,
                            idleEvictionPenalty: Double) -> Double {
        guard reloadCostSeconds.isFinite, reloadCostSeconds > 0,
              idleEvictionPenalty > 0 else { return 0 }
        return reloadCostSeconds / idleEvictionPenalty
    }

    /// The idle window a resident has earned.
    ///
    ///     threshold = max(configuredBase, reloadCost / penalty)
    ///
    /// Two deliberate properties:
    ///
    ///  - **The configured base is a floor, never a ceiling.** Raising the
    ///    window for a resident whose reload outlasts it is the whole
    ///    point (an ANE STT with a measured 200 s reload must not be swept
    ///    at 120 s); *lowering* it would be the warden evicting a resident
    ///    more eagerly than the shipped policy, which is not a change the
    ///    cost model is allowed to make on its own.
    ///  - **A pressed working set suppresses the extension entirely.** The
    ///    `footprintSample` stream is what says so: when the measured `W(t)`
    ///    has grown past what the class budget assumed, the app — not the
    ///    models — is the problem, and a warden that responds by holding
    ///    models *longer* is lengthening the wrong thing. Every shipped
    ///    value is unchanged by this (the base is 120 s and only a measured
    ///    reload above it moves anything), which is what keeps Step 3 out
    ///    of the TTL constants' way.
    static func idleThresholdSeconds(configuredBase: TimeInterval,
                                     reloadCostSeconds: Double,
                                     idleEvictionPenalty: Double,
                                     workingSetIsPressed: Bool) -> TimeInterval {
        guard !workingSetIsPressed else { return configuredBase }
        let earned = holdSeconds(reloadCostSeconds: reloadCostSeconds,
                                 idleEvictionPenalty: idleEvictionPenalty)
        return max(configuredBase, earned)
    }

    /// The manager's `idleThresholdSeconds` for one resident.
    func idleThresholdSeconds(slot: ModelSlot,
                              modelID: ModelID?,
                              footprint: ModelFootprint,
                              deviceClass: ModelLifecycleBudget.DeviceClass,
                              configuredBase: TimeInterval,
                              idleEvictionPenalty: Double,
                              workingSetIsPressed: Bool) -> TimeInterval {
        Self.idleThresholdSeconds(
            configuredBase: configuredBase,
            reloadCostSeconds: reloadCostSeconds(slot: slot,
                                                 modelID: modelID,
                                                 footprint: footprint,
                                                 deviceClass: deviceClass),
            idleEvictionPenalty: idleEvictionPenalty,
            workingSetIsPressed: workingSetIsPressed)
    }

    // MARK: The working set

    /// The most recent `W(t)` reading for a class, or `nil` before any
    /// sample. Saturating; see `ModelFootprintCostSample.workingSetBytes`.
    func workingSetBytes(for deviceClass: ModelLifecycleBudget.DeviceClass) -> UInt64? {
        footprints[deviceClass]?.last?.workingSetBytes
    }

    /// The lowest ceiling the kernel has reported for a class. The
    /// proposal's §3.2 table is built on an *estimate* of the jetsam
    /// ceiling; this is the only place the app can see the real one, and
    /// recording the minimum is the conservative half of the pair (a
    /// generous reading must not be able to relax the class budget).
    func observedCeilingBytes(for deviceClass: ModelLifecycleBudget.DeviceClass) -> UInt64? {
        let readings = (footprints[deviceClass] ?? []).map(\.ceilingBytes)
        return readings.isEmpty ? nil : readings.min()
    }

    /// The keys with at least one measurement, for diagnostics and tests.
    func measuredKeys() -> [(slot: ModelSlot, modelID: ModelID?)] {
        samples.compactMap { key, bucket in
            bucket.isEmpty ? nil : (key.slot, key.modelID)
        }
    }

    /// Everything the model knows, as a flat list for a diagnostics seam.
    func snapshotSamples() -> [ModelLoadCostSample] {
        samples.flatMap { key, bucket in
            bucket.map {
                ModelLoadCostSample(slot: key.slot,
                                    modelID: key.modelID,
                                    deviceClass: key.deviceClass,
                                    loadMs: $0,
                                    at: lastSampleAt ?? Date(timeIntervalSince1970: 0))
            }
        }
    }

    // MARK: Helpers

    /// Nearest-rank percentile on an already-sorted array. Deliberately not
    /// an interpolating definition: with eight samples the difference
    /// matters, and "the value at or above 95 % of observations" is the
    /// sentence the prior and the measurement are compared in.
    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        let index = min(sorted.count - 1, max(0, rank - 1))
        return sorted[index]
    }
}
