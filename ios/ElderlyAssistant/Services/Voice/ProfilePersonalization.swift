import Foundation

// MARK: - Profile read seam (profile-interview, T-091, C07)
//
// The one seam the interpreters (prompt side) and the wake
// acknowledgment (spoken side) consume. Read-only: it never writes the
// store, never mutates the term, and never substitutes a placeholder —
// absent, unreadable, empty and quarantined all mean "run
// un-personalized" (FR-PI-011).
//
// The ADR-09 asymmetry is deliberate and load-bearing: the prompt side
// takes the GUARDED term (contained as quoted data), while the spoken
// side takes the VERBATIM stored term — the user always hears what they
// recorded, even when the prompt-side guard would drop it.

protocol ProfilePersonalizationReading: AnyObject {
    /// Guarded term for prompt composition; nil = un-personalized.
    var addressAsForPrompt: String? { get }
    /// The stored term, verbatim, for the wake acknowledgment; nil when
    /// absent/unreadable/empty. Never guard-processed (ADR-09 asymmetry).
    var addressAsVerbatim: String? { get }
}

final class ProfilePersonalization: ProfilePersonalizationReading {

    private let storage: UserProfileStoring
    private let promptGuard: ProfilePromptTextGuard
    private let observabilityBus: ObservabilityBus?

    init(storage: UserProfileStoring,
         promptGuard: ProfilePromptTextGuard,
         observabilityBus: ObservabilityBus?) {
        self.storage = storage
        self.promptGuard = promptGuard
        self.observabilityBus = observabilityBus
    }

    /// Loaded and not blank → the stored value EXACTLY as recorded (the
    /// store's merge trims on the way in; this accessor never alters the
    /// term). `.absent`, `.unreadable` and blank values are nil — a
    /// placeholder is never substituted (FR-PI-011).
    var addressAsVerbatim: String? {
        guard case .loaded(let profile) = storage.load() else { return nil }
        let term = profile.addressAs
        guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return term
    }

    /// Guard evaluation runs per read (no caching of the verdict). The
    /// quarantine event fires exactly when a real term (non-blank, so
    /// non-nil verbatim) is dropped by the guard — content-free
    /// (outcome only, no metadata, never the term) and never in a loop.
    /// Reads that return a value, and reads of blank/unrecorded values,
    /// emit nothing.
    var addressAsForPrompt: String? {
        guard let term = addressAsVerbatim else { return nil }
        if let guarded = promptGuard.guarded(term) { return guarded }
        observabilityBus?.emit(ObservabilityEvent(
            component: "profile_guard",
            eventType: "profile_prompt_text_quarantined",
            durationMs: nil,
            outcome: "quarantined",
            errorCode: nil,
            metadata: [:]
        ))
        return nil
    }
}
