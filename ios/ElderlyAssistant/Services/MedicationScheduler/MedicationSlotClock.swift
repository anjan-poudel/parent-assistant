import Foundation

// MARK: - Slot model vocabulary (FR-MSR-001)
//
// The slot model replaces "the family types a clock time for every dose"
// with three named times of day. A slot carries no hour or minute of its
// own: the exact clock time comes from the household mapping
// (`MedicationSlotClock`), resolved at arming time, so re-timing a dose
// is one mapping edit and never a rewrite of every entry. These types
// live in this file (design-l2 C1 / L1 §19): `MedicationEntry` and the
// editor reference them; they own none of them.

/// The three times of day a dose can be created at (FR-MSR-001).
enum MedicationSlot: String, Codable, CaseIterable {
    case morning
    case afternoon
    case evening
}

/// Before-meal / after-meal context attached to a dose (FR-MSR-001).
///
/// Context only, never a clock (design-l1 §4.2, OD-1): it is rendered in
/// copy and on the dose screen, and it never produces a second firing or
/// moves the resolved time.
enum MealRelation: String, Codable {
    case beforeMeal
    case afterMeal
}

// MARK: - Quantity types (FR-MSR-001)

/// A structured dose quantity: an amount plus a unit.
///
/// `unit` is a `MedicationDoseUnit` raw value when the family picked one
/// of the seven built-in units, or the family's own words when they did
/// not — the purpose chip-or-free-text precedent (`MedicationPurpose`),
/// applied to units. The amount (a positive integer) is validated at
/// the editor; this type only carries the saved value.
struct MedicationQuantity: Codable, Equatable {
    let amount: Int
    let unit: String
}

/// The seven built-in dose units (FR-MSR-001). A unit string matching no
/// case is family free text, stored and rendered verbatim.
enum MedicationDoseUnit: String, Codable, CaseIterable {
    case tablet
    case capsule
    case milliliter
    case teaspoon
    case drop
    case puff
    case sachet
}

// MARK: - Time of day

/// An exact clock time with hour and minute and nothing else — the shape
/// the shipped scheduler already consumes (`MedicationEntry.scheduleTimes`
/// keeps `.hour`/`.minute` only), so resolution feeds the arming path
/// with no conversion step that could introduce a second or a fractional
/// component.
struct TimeOfDay: Codable, Equatable {
    let hour: Int
    let minute: Int

    /// What the decode below substitutes for a component the stored
    /// payload does not carry (or does not carry as an integer).
    /// Deliberately outside every valid range, so a value holding it can
    /// only ever fail resolution: it is never mistaken for a time, never
    /// clamped, never rounded and never defaulted.
    static let unsetComponent = Int.min

    /// A time of day with both components unset (see `unsetComponent`):
    /// nothing about it is trusted and it can never resolve.
    static let unset = TimeOfDay(hour: unsetComponent, minute: unsetComponent)

    /// True when both components are within their real ranges — hour
    /// 0...23, minute 0...59. Anything else (including `unset`) has no
    /// determinate meaning and must never resolve.
    var isDeterminate: Bool {
        (0...23).contains(hour) && (0...59).contains(minute)
    }

    /// The exact-time arming shape the shipped scheduler consumes: hour
    /// and minute only, never a second or a fractional component.
    var dateComponents: DateComponents {
        DateComponents(hour: hour, minute: minute)
    }

    /// Explicit keys because `init(from:)` is hand-written (the
    /// `MedicationEntry` precedent); encode stays synthesized.
    private enum CodingKeys: String, CodingKey {
        case hour, minute
    }
}

extension TimeOfDay {
    /// Tolerant, fail-closed decode of a stored time of day:
    ///
    /// - a missing or non-integer component decodes as `unsetComponent`
    ///   rather than throwing — one corrupt component must not take the
    ///   whole household mapping down with it, and it must not be
    ///   repaired into a plausible time either;
    /// - present integer components decode AS-IS, including out-of-range
    ///   values: range checking is resolution's job (`isDeterminate`),
    ///   so corruption surfaces as the typed `.indeterminate(slot:)`
    ///   failure instead of being silently clamped here.
    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            // Not an object at all: no component is stored.
            hour = Self.unsetComponent
            minute = Self.unsetComponent
            return
        }
        hour = (try? container.decode(Int.self, forKey: .hour)) ?? Self.unsetComponent
        minute = (try? container.decode(Int.self, forKey: .minute)) ?? Self.unsetComponent
    }
}

// MARK: - Household slot clock (FR-MSR-002)

/// The one typed failure of slot resolution: the stored mapping cannot
/// yield a determinate hour/minute for the slot. Carries the slot ONLY —
/// no entry identity, no medication name, no clock value — so it can
/// never leak PII when a consumer logs it (the arming consumer emits the
/// `medication_slot_unresolved` event with the slot and nothing else).
enum SlotClockError: Error, Equatable {
    case indeterminate(slot: MedicationSlot)
}

/// The household's slot → clock mapping (FR-MSR-002): the single record
/// that turns a `MedicationSlot` into the exact hour/minute a dose is
/// armed at. Household defaults are morning 08:00, afternoon 13:00 and
/// evening 19:00 (OD-1); the family edits them in the medication settings
/// ("Medicine times") and the scheduler reads them at arming time.
///
/// The three guarantees this type exists to provide:
///
/// - **Totality.** `resolve(slot:)` is a function over the exhaustive
///   three-case `MedicationSlot` enum, switched with no default case:
///   every slot the editor can create has an answer under every
///   mapping — the mapped `TimeOfDay`, or the one typed failure.
/// - **Determinism.** The record is a value with no hidden state, no
///   clock and no IO: identical inputs always produce identical outputs,
///   across repeated calls and any number of store round-trips ("the
///   same inputs always produce the same times", never "anything
///   produces some time"). Nothing is cached that could drift.
/// - **Fail-closed.** When the stored mapping has no determinate
///   hour/minute for a slot — unset components from a half-written
///   payload, or values outside 0...23 / 0...59 — resolution returns
///   `.indeterminate(slot:)` and NO time. Nothing is guessed, clamped or
///   repaired, and the consumer arms nothing for that slot.
///
/// Persistence goes through `MedicationSlotClockStore` (the encrypted
/// store key `medication.slot_clock`). Decoding merges per-slot
/// defaults, so a partial payload still yields a total mapping
/// (NFR-MSR-006): a missing per-slot key decodes as that slot's default,
/// an absent record as `.default`, while a present-but-invalid value
/// decodes as-is and fails resolution. The settings save action is the
/// ONE writer; the scheduler only reads, at arming time.
struct MedicationSlotClock: Codable, Equatable {
    let morning: TimeOfDay
    let afternoon: TimeOfDay
    let evening: TimeOfDay

    /// Household default times (OD-1) as named constants: morning 08:00,
    /// afternoon 13:00, evening 19:00. The exact-time arming shape
    /// (hour + minute only) is the shipped scheduler's.
    static let defaultMorningTime = TimeOfDay(hour: 8, minute: 0)
    static let defaultAfternoonTime = TimeOfDay(hour: 13, minute: 0)
    static let defaultEveningTime = TimeOfDay(hour: 19, minute: 0)

    /// The mapping every household starts from, and the mapping an
    /// absent stored record decodes as.
    static let `default` = MedicationSlotClock(
        morning: defaultMorningTime,
        afternoon: defaultAfternoonTime,
        evening: defaultEveningTime
    )

    /// Explicit keys because `init(from:)` is hand-written (below);
    /// encode stays synthesized.
    private enum CodingKeys: String, CodingKey {
        case morning, afternoon, evening
    }

    /// The stored (possibly indeterminate) value for one slot, with no
    /// judgement — the settings editor renders from this and
    /// validation/resolution decide.
    func time(for slot: MedicationSlot) -> TimeOfDay {
        switch slot {
        case .morning: return morning
        case .afternoon: return afternoon
        case .evening: return evening
        }
    }

    /// Resolution (IF-1): the exact hour/minute to arm this slot at, or
    /// the typed fail-closed error when the stored value cannot yield a
    /// determinate time. Pure — no clock, no IO — so it is idempotent
    /// and safe to call from any context.
    func resolve(slot: MedicationSlot) -> Result<TimeOfDay, SlotClockError> {
        let mapped = time(for: slot)
        guard mapped.isDeterminate else {
            return .failure(.indeterminate(slot: slot))
        }
        return .success(mapped)
    }

    /// Validation (IF-2): every slot must hold a determinate time; the
    /// FIRST offending slot is reported in morning / afternoon / evening
    /// order. The store's save runs this before persisting, and the
    /// settings editor runs it before offering a save.
    static func validate(_ clock: MedicationSlotClock) -> Result<Void, SlotClockError> {
        for slot in MedicationSlot.allCases {
            guard clock.time(for: slot).isDeterminate else {
                return .failure(.indeterminate(slot: slot))
            }
        }
        return .success(())
    }
}

extension MedicationSlotClock {
    /// Tolerant, total decode (NFR-MSR-006), never repair:
    ///
    /// - a per-slot key that is ABSENT decodes as that slot's default —
    ///   the migration rule; a partial payload still yields a total
    ///   mapping and no household's schedule is lost to a missing key;
    /// - a per-slot key that is present but not a time record decodes as
    ///   an unset time (inside `TimeOfDay.init(from:)`) and resolves
    ///   `.indeterminate` — the failure is carried forward to
    ///   resolution, not swallowed and not repaired;
    /// - a payload that parses but is not a slot-clock object at all
    ///   decodes as unset for every slot: nothing about it is trusted.
    ///
    /// Values that DO decode are taken as-is, including out-of-range
    /// hours and minutes — range checking is resolution's job, so a
    /// corrupt value surfaces as a typed failure rather than being
    /// clamped into a plausible time here.
    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            morning = .unset
            afternoon = .unset
            evening = .unset
            return
        }
        morning = Self.decodeSlot(container, forKey: .morning,
                                  fallback: Self.defaultMorningTime)
        afternoon = Self.decodeSlot(container, forKey: .afternoon,
                                    fallback: Self.defaultAfternoonTime)
        evening = Self.decodeSlot(container, forKey: .evening,
                                  fallback: Self.defaultEveningTime)
    }

    private static func decodeSlot(_ container: KeyedDecodingContainer<CodingKeys>,
                                   forKey key: CodingKeys,
                                   fallback: TimeOfDay) -> TimeOfDay {
        guard container.contains(key) else { return fallback }
        return (try? container.decode(TimeOfDay.self, forKey: key)) ?? .unset
    }
}

// MARK: - Slot clock store (IF-3 / IF-4)

/// Thin, stateless store for the household mapping over the encrypted
/// local storage seam. One instance is composed and shared: the
/// scheduler reads it at arming time; the coordinator writes it from the
/// settings save action — the ONE writer in the feature.
///
/// Both halves are idempotent and safe to repeat: `load` is a pure read,
/// and `save` validates before it persists, so an invalid mapping is
/// refused before any write and a failed save leaves the stored record
/// unchanged (the previous mapping stays in force).
final class MedicationSlotClockStore {
    /// The encrypted-store key for the household mapping (design-l2
    /// §4.2). The value is small and JSON-encodable, like the
    /// scheduler's other keys.
    static let storageKey = "medication.slot_clock"

    private let storage: EncryptedLocalStorage

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
    }

    /// Read (IF-3): non-throwing. An absent record (or one the storage
    /// seam cannot read back at all) loads as `.default` — the state
    /// every installation starts from, and the only unknown a read can
    /// report. A readable record decodes through the merge rules on
    /// `MedicationSlotClock.init(from:)`: missing keys default per slot,
    /// corrupt values are kept as-is and fail at resolution — never
    /// here, and never silently.
    func load() -> MedicationSlotClock {
        switch storage.read(key: Self.storageKey, type: MedicationSlotClock.self) {
        case .success(let clock):
            return clock
        case .failure:
            return .default
        }
    }

    /// Write (IF-4): validate first, then persist. An invalid mapping is
    /// refused before any write happens and reported through the seam's
    /// write-failure case — nothing was written, so nothing may claim it
    /// was, and the stored record is untouched. (The settings save
    /// action validates through `MedicationSlotClock.validate` first and
    /// surfaces `.indeterminate(slot:)` itself; this guard is the
    /// backstop for any other caller.)
    func save(_ clock: MedicationSlotClock) -> Result<Void, StorageError> {
        guard case .success = MedicationSlotClock.validate(clock) else {
            return .failure(.encryptedWriteFailed)
        }
        return storage.write(key: Self.storageKey, value: clock)
    }
}
