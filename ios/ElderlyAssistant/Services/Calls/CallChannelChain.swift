// NEW file: Services/Calls/CallChannelChain.swift
import Foundation

/// The call-launch preference chain (FR-CDP-007/008): preferred →
/// secondary → phone (the GSM hard floor), deduped, each channel
/// attempted at most once, never dead-ends. Pure and static — no
/// coordinator, no platform probes: every environment fact is an
/// argument (Constraint 12).
enum CallChannelChain {

    /// The environment facts the chain consults (FR-CDP-004/005/006) —
    /// both LOCAL-only (NFR-CDP-002).
    struct Feasibility: Equatable {
        /// A Messenger handle is on file for the target — never whether
        /// the Messenger app is installed (Constraint 2).
        let messengerHandleAvailable: Bool
        /// `canOpenURL("whatsapp://")`, injected by the caller (Constraint 3).
        let whatsAppInstalled: Bool
    }

    /// The routing outcome. `fellBackFrom` is the provenance every
    /// announcement composes from (FR-CDP-008): the skipped channels in
    /// attempt order, empty when the preferred channel was routed.
    struct Result: Equatable {
        let channel: CallApp
        let fellBackFrom: [CallApp]
    }

    // MARK: feasibility

    /// FaceTime and phone are always feasible (FR-CDP-006); phone is the
    /// hard floor and the chain's terminal (Constraint 1).
    static func isFeasible(_ channel: CallApp, feasibility: Feasibility) -> Bool {
        switch channel {
        case .faceTime, .phone: return true
        case .messenger: return feasibility.messengerHandleAvailable
        case .whatsApp: return feasibility.whatsAppInstalled
        }
    }

    /// The deduped attempt order (FR-CDP-007): preferred; secondary when
    /// different; `.phone` appended when absent. Always 1–3 DISTINCT
    /// channels; `.phone` is always IN the order — the route never
    /// dead-ends.
    static func attemptOrder(preferred: CallApp, secondary: CallApp) -> [CallApp] {
        var order: [CallApp] = [preferred]
        if secondary != preferred { order.append(secondary) }
        if !order.contains(.phone) { order.append(.phone) }
        return order
    }

    // MARK: routing

    /// The chain (frozen §3 shape, implemented verbatim). Never
    /// dead-ends: `.phone` is always IN the attempt order, and `.phone`
    /// is always feasible — the loop always returns from inside. The
    /// trailing return keeps the function total without a trap.
    static func route(preferred: CallApp,
                      secondary: CallApp,
                      feasibility: Feasibility) -> Result {
        var skipped: [CallApp] = []
        for candidate in attemptOrder(preferred: preferred, secondary: secondary) {
            if isFeasible(candidate, feasibility: feasibility) {
                return Result(channel: candidate, fellBackFrom: skipped)
            }
            skipped.append(candidate)
        }
        return Result(channel: .phone, fellBackFrom: skipped)   // unreachable
    }

    // MARK: launch-fail candidates (FR-CDP-015; L2-D1/D2)

    /// The hop candidates for a routed channel: the attempt order's
    /// suffix after `routed`, re-applied through the surface vocabulary
    /// (L2-D1). Vocabulary-illegal channels are dropped; when the
    /// filtered list empties, the vocabulary terminal is appended unless
    /// it is the routed channel itself. A vocabulary-SUBSTITUTED routed
    /// channel (not in the attempt order) has NO candidates: the
    /// substitution is the surface's floor, already routed.
    static func hopCandidates(preferred: CallApp,
                              secondary: CallApp,
                              routed: CallApp,
                              vocabulary: CallChannelVocabulary = .anyChannel) -> [CallApp] {
        let order = attemptOrder(preferred: preferred, secondary: secondary)
        var remaining = order.firstIndex(of: routed).map { Array(order[($0 + 1)...]) } ?? []
        remaining = remaining.filter { vocabulary.permits($0) }
        if remaining.isEmpty, vocabulary.terminal != routed {
            remaining = [vocabulary.terminal]
        }
        return remaining
    }

    /// The next attempt after a failed open: the first remaining
    /// candidate that can be attempted at all. Only Messenger is dropped
    /// without a handle on file (data-authoritative — the open cannot
    /// work); WhatsApp is attempted even when the earlier probe said
    /// absent (best-effort — the stale-probe residual is exactly what
    /// this hop covers; the open then lands on the shipped
    /// `needsNativeCompose` / `copiedNumber` recoveries, RES-10).
    /// `nil` is exhaustion: a defined state — the caller's shipped
    /// failure line already spoke, and nothing more is said.
    static func nextLaunchFailCandidate(after failed: CallApp,
                                        attemptOrder: [CallApp],
                                        messengerHandleAvailable: Bool) -> CallApp? {
        attemptOrder.first { candidate in
            candidate != failed
                && (candidate != .messenger || messengerHandleAvailable)
        }
    }

    // MARK: WhatsApp probe (FR-CDP-005)

    /// The probe URL — a compile-time literal, valid by construction
    /// (same form and rationale as the shipped constant at
    /// `AppCoordinator.swift:7270`).
    static let whatsAppProbeURL = URL(string: "whatsapp://")!

    /// The injected probe (Constraint 3): `canOpenURL` arrives as a
    /// closure so tests stub it. Any `false` (including a platform
    /// refusal) means "not installed", immediately — no caching, no
    /// polling, no timeout (NFR-CDP-004); the launch-fail hop covers the
    /// staleness residual (frozen Risks).
    static func whatsAppInstalled(canOpen: (URL) -> Bool) -> Bool {
        canOpen(whatsAppProbeURL)
    }

    // MARK: channel ↔ method (frozen §5 mapping; FR-CDP-012)

    /// The `CallMethod` a channel executes as, by call type. WhatsApp
    /// has one chat-shaped method for both call types (the surface has
    /// no call-type split).
    static func method(for channel: CallApp, isVideo: Bool) -> CallMethod {
        switch channel {
        case .phone: return .phone
        case .faceTime: return isVideo ? .facetimeVideo : .facetimeAudio
        case .messenger: return isVideo ? .messengerVideo : .messengerAudio
        case .whatsApp: return .whatsappChat
        }
    }

    /// The inverse mapping (`requestCallConfirmation` step 3, and the
    /// routed-channel label). Audio and video variants map to the same
    /// channel — the call type is not recoverable from a method alone,
    /// which is why callers keep their own `isVideo`.
    static func channel(for method: CallMethod) -> CallApp {
        switch method {
        case .phone: return .phone
        case .facetimeAudio, .facetimeVideo: return .faceTime
        case .messengerAudio, .messengerVideo: return .messenger
        case .whatsappChat: return .whatsApp
        }
    }

    // MARK: labels (single vocabulary; L2-D8)

    /// The catalog key for a channel — the shipped `app.name.*` keys
    /// verified at `CallingSettingsView.swift:70-77`.
    static func nameKey(for channel: CallApp) -> String {
        switch channel {
        case .faceTime: return "app.name.facetime"
        case .phone: return "app.name.phone"
        case .messenger: return "app.name.messenger"
        case .whatsApp: return "app.name.whatsapp"
        }
    }

    /// The localized channel label — used by the confirmation disclosure
    /// and both announcements; the picker delegates here too (L2-D8).
    static func label(_ channel: CallApp, locale: Locale) -> String {
        L10n.str(nameKey(for: channel), locale: locale)
    }
}

/// The call surfaces' channel vocabulary (ADR-CDP-04) — applied at the
/// AppCoordinator seam only; the frozen `route` is untouched. Reuses the
/// shipped `CallApp.supportsAudio` / `supportsVideo` gates
/// (`CallLinks.swift:80-83`), so the vocabulary IS the shipped button
/// semantics, not a second table.
enum CallChannelVocabulary: Equatable {
    /// All four channels; the GSM floor (address-book rows, voice path).
    case anyChannel
    /// FaceTime excluded — audio buttons and missed-call dial-back.
    case audio
    /// The GSM dialer excluded — video buttons.
    case video

    func permits(_ app: CallApp) -> Bool {
        switch self {
        case .anyChannel: return true
        case .audio: return app.supportsAudio
        case .video: return app.supportsVideo
        }
    }

    /// The always-feasible channel of this vocabulary — where the seam
    /// substitutes a routed channel the surface may not open.
    var terminal: CallApp {
        switch self {
        case .anyChannel, .audio: return .phone
        case .video: return .faceTime
        }
    }

    /// Step 1 normalization of the preferred input (ADR-CDP-04). The
    /// substitution is SILENT (no `fellBackFrom` entry): it is the
    /// shipped button gate, not a feasibility skip — today's
    /// `guard resolved.supportsAudio else { return .phone }` also
    /// returned without a word.
    func normalized(_ app: CallApp) -> CallApp {
        permits(app) ? app : terminal
    }
}
