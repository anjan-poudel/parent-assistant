#if DEBUG
import UIKit

/// Device-driving hook for the Messenger deep-link forms (2026-10-13,
/// field evidence: the first username fix's `m.me` link was not captured
/// by the installed app — Safari opened and redirected to the App Store
/// — while the code still claimed `.openedThread`). The probe lets the
/// verification lanes drive the real decision over USB/network with NO
/// on-device taps and no voice: launch arguments request it, the app
/// runs the same coordinator path a tap reaches, and every decision
/// prints to stdout (`devicectl device process launch --console`
/// streams it).
///
///   -probeMessengerHandle <handle>   the handle to open; `auto` picks the
///                                    first family contact with a usable
///                                    handle (required)
///   -probeDelay <seconds>            settle delay before firing (default 2)
///   -probeMode claims|open|both      what to run (default both)
///
/// Print contract:
///   [PROBE] canOpenURL(fb-messenger://) -> …
///       the installed check, answered by the platform itself
///   [PROBE] universalLinksOnly <url> -> true/false     (claims mode)
///       true  = the system routes the HTTPS link into an installed app
///       false = it would open in Safari (the m.me regression)
///   [PROBE] running performSystemContactMessenger(handle:)   (open mode)
///       the real shipped path, launched from OUR app's foreground —
///       claims run first would background us and confound the open
///   [PROBE] applicationState after open -> …
///       2 (background) == something else took the screen; WHICH app is
///       the screenshot's job (see MessengerProbeUITests)
///
/// `#if DEBUG` by construction: no Release binary contains the hook, and
/// with no launch argument present it is inert.
enum MessengerProbe {

    static func runIfRequested(on coordinator: AppCoordinator) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let handle = value(for: "-probeMessengerHandle", in: arguments) else { return }
        let delay = Double(value(for: "-probeDelay", in: arguments) ?? "") ?? 2
        let mode = value(for: "-probeMode", in: arguments) ?? "both"
        print("[PROBE] scheduled handle='\(handle)' delay=\(delay)s mode=\(mode)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            fire(handle: handle, mode: mode, on: coordinator)
        }
    }

    private static func fire(handle: String, mode: String, on coordinator: AppCoordinator) {
        // `auto`: use the device's OWN data — the first family contact
        // with a usable Messenger handle — so the evidence covers the
        // real complaint ("call maiya"), not a synthetic stand-in.
        var name = "Probe"
        var effectiveHandle = handle
        if handle == "auto" {
            guard let contact = coordinator.familyContacts.first(where: {
                !CallLinks.messengerHandle($0.messengerHandle ?? "").isEmpty
            }), let stored = contact.messengerHandle else {
                print("[PROBE] auto: no family contact with a usable Messenger handle")
                return
            }
            name = contact.name
            effectiveHandle = stored
            print("[PROBE] auto picked contact='\(contact.name)' handle='\(stored)'")
        }
        let normalized = CallLinks.messengerHandle(effectiveHandle)
        print("[PROBE] normalized='\(normalized)'")
        print("[PROBE] canOpenURL(fb-messenger://) -> \(UIApplication.shared.canOpenURL(CallLinks.messengerProbeURL))")

        if mode == "claims" || mode == "both" {
            // HTTPS candidates only: `.universalLinksOnly` is defined for
            // universal links, and a `true` completion means the system
            // DID hand the link to an installed app — the capture
            // question the m.me regression turned on. (A `true` completion
            // opens the app right then; that IS the verification. The
            // FIRST candidate below is the deciding one: it fires while
            // this app is still foreground.)
            for candidate in httpsCandidates(for: normalized) {
                UIApplication.shared.open(candidate, options: [.universalLinksOnly: true]) { success in
                    print("[PROBE] universalLinksOnly \(candidate.absoluteString) -> \(success)")
                }
            }
        }

        if mode == "open" || mode == "both" {
            let openDelay: Double = mode == "both" ? 4 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + openDelay) {
                print("[PROBE] running performSystemContactMessenger(name: '\(name)', handle: '\(effectiveHandle)')")
                coordinator.performSystemContactMessenger(name: name, handle: effectiveHandle)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    print("[PROBE] applicationState after open -> \(UIApplication.shared.applicationState.rawValue)")
                }
            }
        }
    }

    /// The two HTTPS forms the opener can choose between: Messenger's own
    /// domain (the new username form, the deciding claim) and m.me (the
    /// regressed one — kept in the list to record its standing on this
    /// device alongside the fix).
    private static func httpsCandidates(for handle: String) -> [URL] {
        [CallLinks.messengerUsernameThreadURL(handle: handle),
         CallLinks.messengerWebURL(handle: handle)].compactMap { $0 }
    }

    private static func value(for flag: String, in arguments: [String]) -> String? {
        guard let flagIndex = arguments.firstIndex(of: flag),
              arguments.indices.contains(flagIndex + 1) else { return nil }
        return arguments[flagIndex + 1]
    }
}
#endif
