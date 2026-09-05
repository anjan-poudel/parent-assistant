import Foundation
import MessageUI
import UIKit

/// What a `send_message` intent resolved to (v2 pivot §4.3). Returned by
/// the coordinator's `composeMessage` so `CommandRouter` can emit the
/// right observability event and decide who speaks: the router keeps
/// speaking the model's ack for the shipped native-compose path, while
/// the coordinator speaks the honest line for the deep-link and fallback
/// outcomes (it alone knows which surface actually appeared).
enum MessageComposeOutcome: Equatable {
    /// The native `MFMessageComposeViewController` sheet was presented,
    /// pre-filled — the user's own tap on Send is the confirmation
    /// (Apple platform constraint; same model the SMS path shipped with).
    case nativeComposePresented
    /// WhatsApp opened via `whatsapp://send` with the message pre-filled —
    /// the user still taps send inside WhatsApp (v2 spec §4.3: same
    /// "you still tap send" framing as SMS, never claim it was sent).
    case whatsAppChatOpened
    /// WhatsApp is not installed (canOpenURL failed) — fell back to the
    /// native Messages sheet with the same body, disclosed out loud.
    case fellBackToNativeCompose
    /// Neither WhatsApp nor Messages can take text on this device — the
    /// message was copied to the pasteboard as the last resort, disclosed
    /// out loud.
    case copiedTextOnly
    /// No contact could be resolved (or the resolved contact has no
    /// usable phone handle) — the router speaks its existing
    /// contact-not-found line.
    case contactNotFound
}

/// Test seam for URL opening — mirrors how the shipped call flow opens
/// `tel:`/`facetime:` links (`UIApplication.shared.open` in
/// `AppCoordinator.performCallAction`), abstracted so tests can fake it
/// and assert the exact URLs and decisions.
protocol CallLinkOpening {
    func canOpenURL(_ url: URL) -> Bool
    func open(_ url: URL)
}

/// Production opener — `UIApplication`, with the same main-queue hop the
/// shipped call flow uses. `canOpenURL` must run on the main thread.
struct SystemCallLinkOpener: CallLinkOpening {
    func canOpenURL(_ url: URL) -> Bool {
        if Thread.isMainThread { return UIApplication.shared.canOpenURL(url) }
        return DispatchQueue.main.sync { UIApplication.shared.canOpenURL(url) }
    }

    func open(_ url: URL) {
        DispatchQueue.main.async { UIApplication.shared.open(url) }
    }
}

/// Builds and opens the calling/messaging deep links (v2 pivot Phase 2,
/// §4.3): FaceTime video (`facetime://`), FaceTime audio
/// (`facetime-audio://`), WhatsApp outbound text (`whatsapp://send`), the
/// shipped WhatsApp chat link (`https://wa.me/`), and plain `tel:`.
///
/// One home for every outbound URL the call/message flow dials, so handle
/// normalization (e164 digits), percent-encoding, and app-absent
/// decisions are built once and tested once instead of being re-derived
/// per call site. FaceTime genuinely initiates the call; WhatsApp has no
/// public send API, so the text link only opens a pre-filled chat — the
/// user still taps send (documented on every outcome, never claimed as
/// "sent").
final class CallLinks {

    /// Result of attempting a FaceTime deep link.
    enum FaceTimeOutcome: Equatable {
        /// The URL was built and opened.
        case opened
        /// The contact's phone normalized to nothing dialable.
        case invalidHandle
        /// FaceTime can't be opened on this device (near-impossible on
        /// iPhone, real on simulator) — caller must say so gracefully
        /// rather than claim a call was placed.
        case unavailable
    }

    /// Result of attempting a WhatsApp outbound-text link.
    enum WhatsAppTextOutcome: Equatable {
        /// `whatsapp://send` opened with the pre-filled text.
        case openedWhatsApp
        /// WhatsApp is not installed, but the native Messages sheet can
        /// take the same body — caller presents it and discloses the swap.
        case needsNativeCompose
        /// No messaging surface at all — the text was copied to the
        /// pasteboard; caller discloses that.
        case copiedText
        /// The contact's phone normalized to no digits.
        case invalidPhone
    }

    private let opener: CallLinkOpening
    /// Whether the native Messages compose sheet can take text
    /// (`MFMessageComposeViewController.canSendText`) — injected because
    /// the class method isn't fakeable and returns false on simulator.
    private let canSendText: () -> Bool
    /// Pasteboard write for the last-resort copy fallback — injected so
    /// tests can assert the copied body without touching UIPasteboard.
    private let copyText: (String) -> Void

    init(opener: CallLinkOpening = SystemCallLinkOpener(),
         canSendText: @escaping () -> Bool = { MFMessageComposeViewController.canSendText() },
         copyText: @escaping (String) -> Void = { UIPasteboard.general.string = $0 }) {
        self.opener = opener
        self.canSendText = canSendText
        self.copyText = copyText
    }

    // MARK: - Handle normalization

    /// Phone-handle form for `tel:`/`facetime:`: digits with a single
    /// leading `+` preserved when present ("+977-9841 23 45 67" →
    /// "+9779841234567"). Stricter than a raw character filter — a `+`
    /// anywhere else is a typo, not a country code.
    static func phoneHandle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.filter { $0.isNumber }
        return trimmed.hasPrefix("+") ? "+" + digits : digits
    }

    /// E.164 digits only — WhatsApp's `phone=` parameter and the `wa.me`
    /// path both want the number with no `+`, dashes, or spaces.
    static func whatsAppDigits(_ raw: String) -> String {
        raw.filter { $0.isNumber }
    }

    /// Does a `requestedApp` slot name WhatsApp? Shared vocabulary with
    /// `MethodResolver` (call path) so the call and message flows agree
    /// on what counts as naming WhatsApp, in either script.
    static func isWhatsAppName(_ app: String) -> Bool {
        let a = app.lowercased()
        return a.contains("whatsapp") || a.contains("ह्वाट्सएप") || a.contains("वाट्सएप")
    }

    // MARK: - URL builders (pure)

    /// `tel:<handle>` — nil when the handle normalizes to empty.
    static func phoneURL(_ rawPhone: String) -> URL? {
        let handle = phoneHandle(rawPhone)
        guard !handle.isEmpty else { return nil }
        return URL(string: "tel:\(handle)")
    }

    /// `facetime://<handle>` (video) or `facetime-audio://<handle>`
    /// (audio-only). The handle is the contact's phone — `FamilyContact`
    /// carries no email field, and FaceTime accepts a phone handle
    /// directly. Nil when the handle normalizes to empty.
    static func faceTimeURL(handle rawHandle: String, video: Bool) -> URL? {
        let handle = phoneHandle(rawHandle)
        guard !handle.isEmpty else { return nil }
        return URL(string: "\(video ? "facetime" : "facetime-audio")://\(handle)")
    }

    /// `https://wa.me/<digits>` — opens the chat with no pre-filled text
    /// (shipped `.whatsappChat` call behavior, kept byte-identical).
    static func whatsAppChatURL(phone rawPhone: String) -> URL? {
        let digits = whatsAppDigits(rawPhone)
        guard !digits.isEmpty else { return nil }
        return URL(string: "https://wa.me/\(digits)")
    }

    /// `whatsapp://send?phone=<digits>&text=<encoded>` — opens the chat
    /// with the message pre-filled; the user still taps send (v2 §4.3).
    /// Built via URLComponents so Nepali text and punctuation percent-
    /// encode correctly. Nil when the phone has no digits.
    static func whatsAppTextURL(phone rawPhone: String, text: String) -> URL? {
        let digits = whatsAppDigits(rawPhone)
        guard !digits.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "whatsapp"
        components.host = "send"
        var items = [URLQueryItem(name: "phone", value: digits)]
        if !text.isEmpty {
            items.append(URLQueryItem(name: "text", value: text))
        }
        components.queryItems = items
        return components.url
    }

    // MARK: - Openers (decisions + side effects)

    /// Opens `tel:` for the contact's phone. Matches shipped behavior:
    /// no canOpenURL gate (the Phone app is always present on iPhone).
    /// Returns false only when the handle was unusable.
    @discardableResult
    func openPhone(_ rawPhone: String) -> Bool {
        guard let url = Self.phoneURL(rawPhone) else { return false }
        opener.open(url)
        return true
    }

    /// Opens a FaceTime video/audio deep link. Unlike `tel:`, this is
    /// gated on `canOpenURL` — FaceTime is near-universal on iPhone but
    /// absent on simulator, and claiming a call was placed when nothing
    /// opened is exactly the dishonesty the confirmation flow exists to
    /// prevent.
    func openFaceTime(handle rawHandle: String, video: Bool) -> FaceTimeOutcome {
        guard let url = Self.faceTimeURL(handle: rawHandle, video: video) else {
            return .invalidHandle
        }
        guard opener.canOpenURL(url) else { return .unavailable }
        opener.open(url)
        return .opened
    }

    /// Opens the shipped WhatsApp chat link (no text). Unconditional, as
    /// shipped: `wa.me` is an https universal link, so `canOpenURL` can't
    /// distinguish "WhatsApp installed" from "Safari shows the download
    /// page" — the honest detection only exists for the `whatsapp://`
    /// scheme (see `openWhatsAppText`).
    @discardableResult
    func openWhatsAppChat(_ rawPhone: String) -> Bool {
        guard let url = Self.whatsAppChatURL(phone: rawPhone) else { return false }
        opener.open(url)
        return true
    }

    /// Opens `whatsapp://send` with the message pre-filled, or decides
    /// the app-absent fallback (v2 §4.3 + task spec): Messages sheet when
    /// it can take text, pasteboard copy as the last resort. The caller
    /// performs the fallback presentation/disclosure — CallLinks stays at
    /// the URL level and never presents UI.
    func openWhatsAppText(_ rawPhone: String, text: String) -> WhatsAppTextOutcome {
        guard let url = Self.whatsAppTextURL(phone: rawPhone, text: text) else {
            return .invalidPhone
        }
        if opener.canOpenURL(url) {
            opener.open(url)
            return .openedWhatsApp
        }
        if canSendText() {
            return .needsNativeCompose
        }
        copyText(text)
        return .copiedText
    }
}
