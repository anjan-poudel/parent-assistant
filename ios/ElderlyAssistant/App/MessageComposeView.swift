import SwiftUI
import MessageUI

/// Bridges `MFMessageComposeViewController` into SwiftUI for the
/// `send_message` voice intent (trial wiring). iOS never allows a
/// third-party app to send SMS silently on the user's behalf — this
/// sheet always requires the user's own tap on Send, which is the most
/// "real" this feature can honestly be on-platform.
struct MessageComposeView: UIViewControllerRepresentable {
    let draft: AppCoordinator.MessageDraft
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.recipients = draft.recipients
        controller.body = draft.body
        controller.messageComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        private let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                          didFinishWith result: MessageComposeResult) {
            controller.dismiss(animated: true, completion: onFinish)
        }
    }
}
