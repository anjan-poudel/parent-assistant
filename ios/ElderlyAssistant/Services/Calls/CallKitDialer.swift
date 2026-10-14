// NEW file: Services/Calls/CallKitDialer.swift (callkit-gsm, 2026-10-14)
import Foundation
#if canImport(CallKit)
import CallKit
#endif

/// The GSM dialer's outcome — the caller's decision input (callkit-gsm,
/// 2026-10-14).
///
/// The owner report this exists for: asking the assistant to call a
/// contact opened iOS's system confirmation sheet (the phone number plus
/// Open/Cancel — the SYSTEM prompt every `tel:` open raises, in the
/// device language, suppressible by nothing). CallKit's
/// `CXStartCallAction` places the native GSM call with NO such prompt,
/// so the app's own localized confirmation (the spoken yes/no seam that
/// already ships) remains the only confirmation the user ever sees.
enum CallKitDialOutcome: Equatable {
    /// The `CXStartCallAction` was handed to CallKit — the native call
    /// is being placed with the system's ordinary in-call UI and no
    /// confirmation prompt. The caller proceeds exactly as after a
    /// successful `tel:` open (speak "calling", record the activity).
    case requested
    /// The number carried no dialable digits — neither CallKit nor the
    /// `tel:` fallback can dial. Nothing was submitted; the caller
    /// speaks its shipped honest no-number line.
    case invalidNumber
}

/// The `CXHandle` value for a phone number (pure — the Foundation-only
/// half tests drive directly, the `UnansweredCallTracker` house
/// pattern). One normalization for every GSM path: the same handle form
/// the `tel:` builders use (`CallLinks.phoneHandle` — digits with a
/// single leading `+` preserved; a `+` anywhere else is a typo, not a
/// country code), so CallKit and the `tel:` fallback dial the identical
/// number.
enum CallKitDialRequest {
    /// The dialable handle value for `raw`, or nil when no digits remain
    /// (nothing to dial — the `.invalidNumber` outcome).
    static func numberValue(_ raw: String) -> String? {
        let value = CallLinks.phoneHandle(raw)
        return value.isEmpty ? nil : value
    }
}

/// The submission seam (callkit-gsm, 2026-10-14) — the dialer talks to
/// this protocol, never to `CXCallController` directly, so the request
/// build and the fallback decision are testable with a fake (CallKit's
/// own request pipeline cannot be driven by unit tests — the same thin
/// wall `CallStateProviding` draws for call observation).
protocol CallTransactionSubmitting: AnyObject {
    /// Submit `transaction` to CallKit. `completion` receives nil when
    /// the request was accepted and the CallKit error otherwise; an
    /// implementation may invoke it on any queue.
    func submit(_ transaction: CXTransaction, completion: @escaping (Error?) -> Void)
}

/// Production `CallTransactionSubmitting` backed by `CXCallController`.
/// No entitlement is required for a phone-number handle: the system
/// shows its ordinary in-call UI for the placed call.
final class CXCallControllerSubmitter: CallTransactionSubmitting {
    private let controller = CXCallController()

    func submit(_ transaction: CXTransaction, completion: @escaping (Error?) -> Void) {
        controller.request(transaction, completion: completion)
    }
}

/// The GSM dialer (callkit-gsm, 2026-10-14): places a native phone call
/// through CallKit — `CXStartCallAction` with a `.phoneNumber` handle,
/// `isVideo = false` — so NO system confirmation prompt stands between
/// the app's own localized confirmation and the call (a `tel:` open
/// always raises that prompt; nothing can suppress it).
///
/// Failure is graceful by design: a number that normalizes to no digits
/// is `.invalidNumber` (nothing dialable anywhere — no submission, no
/// fallback can help), and a CallKit error AFTER submission delivers the
/// injected `onFailure` fallback, so the caller keeps its shipped `tel:`
/// behavior for exactly that case. `dial` itself is synchronous (the
/// request submission is fire-and-forget, like the shipped `tel:` open);
/// a deferred failure fallback is delivered on the main queue, where the
/// coordinator's contracts (speech, state, the `tel:` open) live.
final class CallKitDialer {

    private let submitter: CallTransactionSubmitting
    /// How a deferred failure fallback is delivered — the main queue in
    /// production, injectable so tests run synchronously (Constraint 12:
    /// every environment fact is an argument).
    private let deliver: (@escaping () -> Void) -> Void

    init(submitter: CallTransactionSubmitting = CXCallControllerSubmitter(),
         deliver: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.submitter = submitter
        self.deliver = deliver
    }

    /// Request a native GSM call to `phoneNumber`.
    ///
    /// `.requested` means the transaction is with CallKit (the native
    /// call, no system prompt). Should CallKit later reject the submitted
    /// request, `fallback` runs (on `deliver`'s queue) — the caller's
    /// shipped `tel:` behavior for exactly that failure. `.invalidNumber`
    /// submitted nothing: no digits, nothing dialable anywhere.
    @discardableResult
    func dial(phoneNumber: String, onFailure fallback: @escaping () -> Void) -> CallKitDialOutcome {
        guard let value = CallKitDialRequest.numberValue(phoneNumber) else {
            return .invalidNumber
        }
        let action = CXStartCallAction(call: UUID(),
                                       handle: CXHandle(type: .phoneNumber, value: value))
        action.isVideo = false
        submitter.submit(CXTransaction(action: action)) { [deliver] error in
            // nil == CallKit accepted the request; anything else is the
            // failure the caller's fallback exists for.
            guard error != nil else { return }
            deliver(fallback)
        }
        return .requested
    }
}
