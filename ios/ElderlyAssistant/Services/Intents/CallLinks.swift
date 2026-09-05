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

/// The app a per-contact call button opens (contact-call-buttons task,
/// 2026-09-06). Stored on `FamilyContact` as that contact's preference;
/// `CallLinks` owns the URL/open behavior per app, so this vocabulary is
/// shared between the storage model and the opener.
///
/// Only apps with a REAL outbound surface are listed (the same bar
/// `CallMethod` holds): FaceTime genuinely initiates the call and `tel:`
/// always works; Messenger and WhatsApp have NO public call-initiation
/// API on iOS, so those buttons open the chat surface and the user taps
/// the call icon inside the app — disclosed out loud, never claimed as
/// "calling" (docs/messaging-calling-platform-research.md).
enum CallApp: String, Codable, Equatable {
    /// FaceTime — the only app that truly starts a call from a deep
    /// link. Video-only in this vocabulary (audio FaceTime stays a
    /// voice-flow `CallMethod`, not a per-contact button target).
    case faceTime
    /// Plain GSM call (`tel:`) — audio only, but works for every
    /// contact with zero app assumptions.
    case phone
    /// Messenger chat surface (video/audio icon inside the app).
    case messenger
    /// WhatsApp chat surface (video/audio icon inside the app).
    case whatsApp

    /// Video buttons may resolve to any app except the GSM dialer.
    var supportsVideo: Bool { self != .phone }
    /// Audio buttons may resolve to any app except FaceTime (kept
    /// video-only for the button path — see above).
    var supportsAudio: Bool { self != .faceTime }
}

/// Which ContactTile button was tapped — the tap IS the confirmation
/// (redesign precedent: a deliberate tap on one's own unlocked phone
/// needs no voice confirmation), so this is the whole "intent".
enum ContactCallKind: Equatable {
    case video
    case audio
}

/// Builds and opens the calling/messaging deep links (v2 pivot Phase 2,
/// §4.3): FaceTime video (`facetime://`), FaceTime audio
/// (`facetime-audio://`), WhatsApp outbound text (`whatsapp://send`), the
/// shipped WhatsApp chat link (`https://wa.me/`), plain `tel:`, and the
/// Messenger thread link (`fb-messenger://user-thread/`, with the
/// `https://m.me/` app-absent fallback).
///
/// One home for every outbound URL the call/message flow dials, so handle
/// normalization (e164 digits, Messenger handle alphabet), percent-
/// encoding, and app-absent decisions are built once and tested once
/// instead of being re-derived per call site. FaceTime genuinely
/// initiates the call; WhatsApp has no public send API, so the text link
/// only opens a pre-filled chat — the user still taps send (documented
/// on every outcome, never claimed as "sent"); Messenger has no public
/// call-initiation scheme at all, so the thread link only opens the
/// conversation — the user still taps the call button (same honesty
/// rule, documented on `MessengerOutcome`).
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

    /// Result of attempting a Messenger thread deep link. There is NO
    /// documented URL that starts a 1:1 Messenger audio/video call (as of
    /// 2026-09 — Rooms/call links are a shareable-link mechanism, not
    /// per-contact dialing), so "opening a Messenger call" means opening
    /// the thread where the call buttons sit, and the outcomes say exactly
    /// which surface appeared.
    enum MessengerOutcome: Equatable {
        /// Messenger is installed — `fb-messenger://user-thread/<handle>`
        /// opened the 1:1 thread; the call buttons are one tap away.
        case openedThread
        /// Messenger is not installed (canOpenURL failed on the
        /// `fb-messenger` scheme — the honest detection, unlike an https
        /// universal link) — `https://m.me/<handle>` was opened via
        /// Safari instead; caller discloses the swap out loud.
        case fellBackToWeb
        /// The contact has no Messenger handle on file (or it normalized
        /// to nothing usable) — nothing opened; caller says so.
        case invalidHandle
    }

    /// Result of a Messenger chat open from a per-contact call button
    /// (contact-call-buttons task). Messenger has no public API to
    /// deep-link a call by phone number, so both outcomes land on a
    /// chat surface and the user taps the call icon inside.
    enum MessengerChatOutcome: Equatable {
        /// Messenger is installed — the app opened (`fb-messenger://`).
        case openedApp
        /// Messenger is not installed — fell back to the
        /// `https://m.me/<digits>` web chat (task's absent-app chain).
        case openedWebChat
        /// The contact's phone normalized to no digits.
        case invalidHandle
    }

    /// Result of a WhatsApp chat open from a per-contact call button.
    /// Distinct from `WhatsAppTextOutcome`: a CALL request carries no
    /// message body, so the last-resort copy payload is the contact's
    /// number, not a text.
    enum WhatsAppCallOutcome: Equatable {
        /// `whatsapp://send` opened the chat in-app — the user taps
        /// the video/audio icon inside WhatsApp.
        case openedChat
        /// WhatsApp is not installed, but the native Messages sheet can
        /// take a text to the same number — caller presents it and
        /// discloses the swap.
        case needsNativeCompose
        /// No messaging surface at all — the contact's number was
        /// copied to the pasteboard; caller discloses that.
        case copiedNumber
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

    /// Messenger-handle form for `fb-messenger://user-thread/` and
    /// `m.me/`: a username (ASCII letters, digits, dots — Facebook's
    /// username alphabet) or a numeric user-id. Trims whitespace and one
    /// leading "@" (family members write handles the way they see them).
    /// Returns "" for anything outside that alphabet — a handle we can't
    /// even shape into a URL is an invalid handle, not a guess. (The set
    /// is hand-listed, NOT `CharacterSet.alphanumerics`, which also
    /// contains Devanagari letters and would let "सीता" through.)
    static func messengerHandle(_ raw: String) -> String {
        var handle = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if handle.hasPrefix("@") { handle.removeFirst() }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789."
        )
        guard !handle.isEmpty,
              handle.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return "" }
        return handle
    }

    /// Does a `requestedApp` slot name WhatsApp? Shared vocabulary with
    /// `MethodResolver` (call path) so the call and message flows agree
    /// on what counts as naming WhatsApp, in either script.
    static func isWhatsAppName(_ app: String) -> Bool {
        let a = app.lowercased()
        return a.contains("whatsapp") || a.contains("ह्वाट्सएप") || a.contains("वाट्सएप")
    }

    /// Does a `requestedApp` slot name Messenger? Shared vocabulary with
    /// `MethodResolver` and `CallOverrideParser`, both scripts, including
    /// the common "fb messenger" phrasing and both Devanagari spellings
    /// (म्यासेन्जर / मेसेन्जर).
    static func isMessengerName(_ app: String) -> Bool {
        let a = app.lowercased()
        return a.contains("messenger") || a.contains("म्यासेन्जर") || a.contains("मेसेन्जर")
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

    /// `fb-messenger://user-thread/<handle>` — deep link INTO the 1:1
    /// thread, where the audio/video call buttons sit one tap away. This
    /// is the best feasible Messenger "call" link: no documented scheme
    /// starts a 1:1 Messenger call directly (research 2026-09; the v2
    /// spec's "no public API" row for Messenger calls still stands — the
    /// user's direction was to ship what IS possible, documented here and
    /// in the outcome strings, never claimed as an auto-started call).
    /// The audio/video distinction is deliberately NOT a parameter: both
    /// land on the same thread URL, and a parameter that changes nothing
    /// would pretend otherwise. Nil when the handle normalizes to empty.
    static func messengerThreadURL(handle rawHandle: String) -> URL? {
        let handle = messengerHandle(rawHandle)
        guard !handle.isEmpty else { return nil }
        return URL(string: "fb-messenger://user-thread/\(handle)")
    }

    /// `https://m.me/<handle>` — the app-absent fallback, opened via
    /// Safari (mirrors the shipped `wa.me` chat link's universal-link
    /// role: when Messenger IS present the thread deep link wins instead,
    /// so this only ever fires for the app-absent case). Nil when the
    /// handle normalizes to empty.
    static func messengerWebURL(handle rawHandle: String) -> URL? {
        let handle = messengerHandle(rawHandle)
        guard !handle.isEmpty else { return nil }
        return URL(string: "https://m.me/\(handle)")
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

    /// Opens the Messenger 1:1 thread for the contact's Messenger handle,
    /// or the app-absent fallback — mirrors `openWhatsAppText`'s shape:
    /// the `fb-messenger` scheme's canOpenURL is the honest installed
    /// check (requires `fb-messenger` in LSApplicationQueriesSchemes),
    /// and the fallback is the `m.me` universal link via Safari, which
    /// the caller discloses out loud. Opens NOTHING for an unusable
    /// handle. CallLinks stays at the URL level — disclosure is the
    /// caller's job, and "the call started" is never claimed by anyone.
    func openMessengerThread(handle rawHandle: String) -> MessengerOutcome {
        guard let threadURL = Self.messengerThreadURL(handle: rawHandle) else {
            return .invalidHandle
        }
        if opener.canOpenURL(threadURL) {
            opener.open(threadURL)
            return .openedThread
        }
        // Thread URL was buildable, so the web URL is too (same handle).
        if let webURL = Self.messengerWebURL(handle: rawHandle) {
            opener.open(webURL)
        }
        return .fellBackToWeb
    }

    /// Opens Messenger for a per-contact call button (contact-call-
    /// buttons task). No public API deep-links a Messenger call by phone
    /// number, so this opens the app's chat surface and the user taps
    /// the video/audio icon inside — the caller's spoken line says
    /// exactly that. Absent-app chain per the task: `fb-messenger://`
    /// when installed, else the `https://m.me/<digits>` web chat.
    /// (`m.me` resolves a phone number only when the person's Facebook
    /// is discoverable by it; otherwise it lands on Messenger web's
    /// home — still a real surface, disclosed as the web fallback.)
    func openMessengerChat(phone rawPhone: String) -> MessengerChatOutcome {
        let digits = Self.whatsAppDigits(rawPhone)
        guard !digits.isEmpty else { return .invalidHandle }
        if let appURL = URL(string: "fb-messenger://"), opener.canOpenURL(appURL) {
            opener.open(appURL)
            return .openedApp
        }
        // https is always openable (Safari); non-empty digits make this
        // URL well-formed, but stay unwrap-free per convention.
        guard let webURL = URL(string: "https://m.me/\(digits)") else { return .invalidHandle }
        opener.open(webURL)
        return .openedWebChat
    }

    /// Opens a WhatsApp chat for a per-contact CALL button (no message
    /// body — `whatsAppTextURL` omits the text parameter when empty, so
    /// the user lands in the chat and taps the video/audio icon; v2 §4.3
    /// "you still tap" framing applies to the call icons too).
    ///
    /// Unlike `openWhatsAppChat`'s unconditional `wa.me`, this IS
    /// presence-gated on the `whatsapp://` scheme — the only honest
    /// installed-check — so an absent app takes the task's fallback
    /// chain: native Messages sheet when it can send text, else the
    /// contact's number on the pasteboard. The caller performs the
    /// fallback presentation/disclosure.
    func openWhatsAppCallChat(_ rawPhone: String) -> WhatsAppCallOutcome {
        guard let url = Self.whatsAppTextURL(phone: rawPhone, text: "") else {
            return .invalidPhone
        }
        if opener.canOpenURL(url) {
            opener.open(url)
            return .openedChat
        }
        if canSendText() {
            return .needsNativeCompose
        }
        copyText(Self.phoneHandle(rawPhone))
        return .copiedNumber
    }
}
