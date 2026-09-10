import SwiftUI

// MARK: - Home presentation state (startup review P1-7, 2026-09-10)
//
// Why these types exist: `HomeView` observes the whole `AppCoordinator`,
// and so did every section of it — computed properties and functions do
// not establish SwiftUI invalidation boundaries, so a feed translation, a
// model-download tick, a settings change or an unrelated timer re-ran the
// Talk hero's body along with everything else on the screen.
//
// The split: `HomeView` reads the coordinator once and hands each extracted
// view a NARROW, value-typed slice of it (these structs). The extracted
// views (`HomeTopBar`, `QuickAccessStrip`, `TalkStage`, `FeedbackRegion`,
// `HomeDock` — see `HomeSubviews.swift`) never observe the coordinator:
// they are `Equatable` and are applied with `.equatable()`, so a parent
// re-render that leaves their slice unchanged skips their bodies entirely.
//
// Equality rule for every extracted view: `==` compares the DATA inputs
// (plus the observed session's identity and state, where one is observed)
// and deliberately ignores action closures. Those closures are re-created
// on every render but always perform the same coordinator call, so any
// value their behavior depends on — e.g. the session state that decides
// what the hero's tap does — must itself be part of the compared data.
// Extending an extracted view therefore means extending its `==`.
//
// iOS 16 is the deployment floor, so these stay value-typed slices fed by
// `HomeView` rather than migrating the monolithic coordinator to
// `@Observable` (the review's P1 note: when the floor moves to iOS 17,
// migrate these to `@Observable` — do not convert the coordinator
// wholesale).

/// The Home chrome's inputs: everything the top bar, the quick-access row
/// and the setup strip render. Fed by `HomeView`; never read from the
/// coordinator by the views themselves.
struct HomePresentationState: Equatable {
    /// Today's composed date line (nil until the first offline
    /// composition lands).
    var dateLine: HomeDateLineComposer.Line?
    /// Active notification panels — the bell badge. Derived by the
    /// coordinator-side pass; Home only renders it.
    var notificationCount: Int
    /// The user's quick-access favourites (empty hides the strip).
    var favoriteApps: [AppLauncher.App]
    /// The top family contact's name, for the dock's call tile avatar.
    var primaryContactName: String?
    /// The optional-setup strip's inputs.
    var setup: SetupPresentation

    static let empty = HomePresentationState(
        dateLine: nil,
        notificationCount: 0,
        favoriteApps: [],
        primaryContactName: nil,
        setup: .hidden)
}

/// The setup strip's inputs (design review: "ready vs optional setup").
///
/// Pending onboarding steps are OPTIONAL — the app is fully usable while
/// they remain — so the strip must not read as "app unusable". Warning
/// styling is reserved for the one case that is genuinely a degradation:
/// a startup capability that failed (`needsAttention`).
struct SetupPresentation: Equatable {
    /// How many optional onboarding steps are still pending. Drives the
    /// count in the localized, parameterized label.
    var pendingCount: Int
    /// True only when a real capability is unavailable — i.e. boot
    /// recorded a failed stage. Never set merely because steps remain.
    var needsAttention: Bool

    static let hidden = SetupPresentation(pendingCount: 0, needsAttention: false)

    var isVisible: Bool { pendingCount > 0 }
}

/// Manual Talk state as the talk stage renders it ([P0-2] + P1-7): the
/// readiness contract plus the two derived labels the stage shows.
struct VoicePresentationState: Equatable {
    /// Manual Talk readiness — the hero's only gate.
    var readiness: VoicePipelineReadiness
    /// Replaces the state's own status line when set (error caption or the
    /// transient post-reset notice).
    var statusOverride: String?
    /// The error state's kind is a permission failure, so the stage offers
    /// the "Open Settings" affordance.
    var showsOpenSettings: Bool

    static let loading = VoicePresentationState(
        readiness: .loading(.starting),
        statusOverride: nil,
        showsOpenSettings: false)
}

/// Navigation-relevant inputs Home derives from the coordinator, kept in
/// one value so no extracted view has to read the coordinator to know
/// where a request wants to go.
struct NavigationPresentationState: Equatable {
    /// Identity of a pending voice-driven contact search (nil = none).
    /// Identity-only: a new request with identical contents must still
    /// push once.
    var pendingContactSearchID: UUID?
    /// Whether the push stack is at the root.
    var isPathEmpty: Bool

    static let idle = NavigationPresentationState(pendingContactSearchID: nil,
                                                  isPathEmpty: true)
}
