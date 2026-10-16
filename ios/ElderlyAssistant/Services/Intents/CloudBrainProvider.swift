import Foundation

/// [CLOUD-CASCADE] (2026-09-16) One cloud provider as the router consumes
/// it — the provider SEAM behind the cloud cascade tier.
///
/// `IntentRouter` never switches on a provider id. It is handed one of
/// these and asks it three questions: which interpreter takes an escalated
/// turn, whether the provider is configured at all, and whether THIS turn
/// may spend a call. Adding a second provider is a `CloudProvider` case
/// plus one branch in `CloudBrainProviders.endpoint(for:)` — the router,
/// the band policy and the cascade tier are untouched by it.
///
/// The endpoint is built by the composition root (`AppCoordinator`), where
/// the interpreters and the key/cost stores actually live, so every
/// readiness input is the SAME one the rest of the app consults
/// (`GeminiConfigStore.isConfigured` / `GeminiCostGovernor.allowsCall()`) —
/// a Settings promise can never outrun what the tier would do.
struct CloudBrainEndpoint {

    /// The provider this endpoint reaches. Logged in the cascade's
    /// observability metadata (`provider`) — an id, never a key.
    let provider: CloudProvider

    /// The stable interpreter token this provider logs as ("gemini").
    let interpreterName: String

    /// The interpreter an escalated turn is routed to.
    let interpreter: CommandInterpreter

    /// Whether the provider has what it needs to be called AT ALL — an API
    /// key. The wiring site reads a missing closure as "not configured"
    /// (the same nil-reads-as-false rule `IntentRouter`'s cloud-first
    /// inputs follow), so an unconfigured provider can never receive a
    /// turn, a cue, or a log line.
    let isConfigured: () -> Bool

    /// Whether THIS turn may spend a call — the day's cost budget.
    let costAllows: () -> Bool

    /// Ready for a turn: the interpreter is up AND a key is configured AND
    /// the budget allows a call. The cascade tier's one readiness gate,
    /// so "configured" means exactly what it means everywhere else in the
    /// chain.
    var isReady: Bool {
        interpreter.isAvailable && isConfigured() && costAllows()
    }
}

/// One provider's registration: the interpreter the composition root built
/// for it plus the two readiness inputs. A registration exists even when
/// the provider is NOT configured (the interpreter object is constructed at
/// startup; the key is a runtime fact) — `isConfigured` is what the tier
/// reads, not the registration's presence.
struct CloudBrainRegistration {

    let interpreter: CommandInterpreter
    let isConfigured: () -> Bool
    let costAllows: () -> Bool

    /// This registration seen as `provider`'s endpoint.
    func endpoint(for provider: CloudProvider) -> CloudBrainEndpoint {
        CloudBrainEndpoint(provider: provider,
                           interpreterName: provider.interpreterName,
                           interpreter: interpreter,
                           isConfigured: isConfigured,
                           costAllows: costAllows)
    }
}

/// [CLOUD-CASCADE] The provider registry — the seam's resolution step, and
/// the ONLY place the app maps a provider id to a brain.
///
/// Pure data + one `switch`: `AppCoordinator` fills it from the interpreters
/// it has constructed (a provider this build cannot reach stays nil), and
/// `IntentRouter` asks it for the endpoint of the provider the household
/// picked (`AppCoordinator.cloudProvider`). A test constructs it with stubs
/// and asserts resolution with no coordinator, no network and no key —
/// which is what makes the seam testable rather than decorative.
struct CloudBrainProviders {

    /// Gemini's registration; nil until `AppCoordinator` has built the
    /// interpreter (the pre-`start()` window) and in every construction
    /// site that wires none.
    var gemini: CloudBrainRegistration?

    init(gemini: CloudBrainRegistration? = nil) {
        self.gemini = gemini
    }

    /// The endpoint `provider` resolves to, or nil when this configuration
    /// cannot reach it. Nil is the tier's "not configured" answer: no cue,
    /// no event, no log — silent, exactly as the ladder behaved before the
    /// tier existed.
    func endpoint(for provider: CloudProvider) -> CloudBrainEndpoint? {
        switch provider {
        case .gemini:
            return gemini?.endpoint(for: .gemini)
        }
    }
}

extension CloudProvider {

    /// The stable interpreter token this provider logs as — the
    /// `interpreter` metadata `InterpreterSelection` already writes for
    /// Gemini, so every cloud-side event reads with one vocabulary.
    var interpreterName: String {
        switch self {
        case .gemini: return "gemini"
        }
    }
}
