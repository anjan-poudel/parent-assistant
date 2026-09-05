import SwiftUI
import UIKit

/// Camera-capture + guidance sheet for the appliance helper (design §5).
/// All pipeline logic lives in `ApplianceHelperSession`; this view only
/// renders `session.state` and forwards camera results.
///
/// Layout contract (design §5.1): the photo renders `.aspectRatio(.fit)`
/// inside a `GeometryReader`, and the `Canvas` overlay recomputes the
/// letterboxed displayed rect via `ApplianceOverlayMapper` on every size
/// change — a pure function of (containerSize, imageSize, box), so there
/// is no stale mapping state to invalidate on rotation/Dynamic Type.
struct ApplianceHelperView: View {

    @ObservedObject var session: ApplianceHelperSession
    @Environment(\.dismiss) private var dismiss
    @State private var showCamera = false
    /// Auto-open the camera once when the sheet appears (the voice turn
    /// already said "show me the appliance"); retakes use the button.
    @State private var didAutoOpenCamera = false
    @State private var pulse = false

    var body: some View {
        NavigationStack {
            ZStack {
                DesignTokens.background.ignoresSafeArea()
                content
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("plugin.applianceHelper.name")
                        .font(DesignTokens.greetingFont(size: 20))
                        .foregroundColor(DesignTokens.textPrimary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(DesignTokens.textSecondary)
                            .accessibilityLabel(Text("appliance.dismiss"))
                    }
                    .frame(minWidth: DesignTokens.minTapTargetSize,
                           minHeight: DesignTokens.minTapTargetSize)
                }
            }
        }
        .onAppear {
            guard !didAutoOpenCamera else { return }
            didAutoOpenCamera = true
            showCamera = true
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker(onImage: { image in
                session.handleCapturedPhoto(image)
            })
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.state {
        case .capturing:
            capturingBody
        case .working:
            workingBody
        case let .guidance(presentation, image):
            guidanceBody(presentation, image: image)
        case let .unavailable(message):
            unavailableBody(message)
        }
    }

    // MARK: - States

    private var capturingBody: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 64))
                .foregroundColor(DesignTokens.accent)
            Text("plugin.applianceHelper.cameraPrompt")
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                showCamera = true
            } label: {
                Label("appliance.takePhoto", systemImage: "camera.fill")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(DesignTokens.accent)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }
            .frame(minHeight: DesignTokens.minTapTargetSize)
            Spacer()
        }
    }

    private var workingBody: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.6)
            Text("appliance.working")
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.textSecondary)
            Spacer()
        }
    }

    private func unavailableBody(_ message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundColor(DesignTokens.stateListening)
            Text(message)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                session.retake()
            } label: {
                Label("appliance.retry", systemImage: "arrow.clockwise")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(DesignTokens.accent)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }
            .frame(minHeight: DesignTokens.minTapTargetSize)
            Spacer()
        }
    }

    // MARK: - Guidance

    private func guidanceBody(_ presentation: ApplianceGuidancePolicy.Presentation,
                              image: UIImage) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                if presentation.hedged {
                    hedgeBanner
                }
                photoWithOverlay(presentation, image: image)
                    .frame(maxWidth: .infinity)
                    .frame(height: 340)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))

                if presentation.showCloserPhotoHint {
                    closerPhotoHint
                }

                stepsCard(presentation)

                Button {
                    session.retake()
                } label: {
                    Label("appliance.retake", systemImage: "camera.rotate.fill")
                        .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                        .foregroundColor(DesignTokens.accent)
                        .frame(minHeight: DesignTokens.minTapTargetSize)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private var hedgeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "questionmark.circle.fill")
                .foregroundColor(DesignTokens.stateListening)
            Text("appliance.hedgeNotice")
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                .foregroundColor(DesignTokens.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(DesignTokens.setupReminder)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
    }

    private var closerPhotoHint: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "viewfinder")
                .foregroundColor(DesignTokens.accent)
            Text("appliance.closerPhotoHint")
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundColor(DesignTokens.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(DesignTokens.userBubble)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
    }

    /// Photo + overlay (design §5.1): fixed-radius high-contrast circle +
    /// step-number badge per visible control — fixed radius rather than
    /// box-scaled, because real buttons are often tiny in a full-panel
    /// photo and a box-accurate circle would be effectively invisible.
    private func photoWithOverlay(_ presentation: ApplianceGuidancePolicy.Presentation,
                                  image: UIImage) -> some View {
        GeometryReader { geometry in
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                Canvas { context, _ in
                    for (index, control) in presentation.visibleControls.enumerated() {
                        let point = ApplianceOverlayMapper.screenPoint(
                            for: control,
                            containerSize: geometry.size,
                            imageSize: image.size)
                        let radius: CGFloat = 14 * (pulse ? 1.15 : 1.0)
                        let rect = CGRect(x: point.x - radius, y: point.y - radius,
                                          width: radius * 2, height: radius * 2)
                        // White under-stroke keeps the orange ring legible
                        // on both dark and busy control panels (don't rely
                        // on color alone — pulse carries attention too).
                        context.stroke(Circle().path(in: rect.insetBy(dx: -1.5, dy: -1.5)),
                                       with: .color(.white), lineWidth: 5)
                        context.stroke(Circle().path(in: rect),
                                       with: .color(DesignTokens.talkGlowEnd), lineWidth: 3.5)
                        let badgeNumber = control.stepNumber ?? (index + 1)
                        let badgeCenter = CGPoint(x: point.x + radius, y: point.y - radius)
                        let badgeRect = CGRect(x: badgeCenter.x - 10, y: badgeCenter.y - 10,
                                               width: 20, height: 20)
                        context.fill(Circle().path(in: badgeRect), with: .color(DesignTokens.talkGlowEnd))
                        context.draw(Text("\(badgeNumber)")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(.white),
                                     at: badgeCenter)
                    }
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    /// The step list is ALWAYS shown as plain text — the overlay is
    /// additive, never load-bearing for understanding (design §2/§7).
    private func stepsCard(_ presentation: ApplianceGuidancePolicy.Presentation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let name = presentation.guidance.identity.displayName
            if !name.isEmpty {
                Text(name)
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(DesignTokens.textPrimary)
            }
            if !presentation.guidance.spokenSummary.isEmpty {
                Text(presentation.guidance.spokenSummary)
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .foregroundColor(DesignTokens.textPrimary)
            }
            ForEach(Array(presentation.guidance.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 26, height: 26)
                        .background(DesignTokens.accent)
                        .clipShape(Circle())
                    Text(step)
                        .font(.system(size: DesignTokens.minBodyPointSize))
                        .foregroundColor(DesignTokens.textPrimary)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }
}

// MARK: - Camera

/// `UIImagePickerController` wrapper (design §9: the built-in picker for
/// v2.0 — standard, accessible, no custom capture UI). Falls back to the
/// photo library where no camera exists (simulator), which also gives the
/// "select an existing photo" path the task allows. The picker UI handles
/// the camera-permission prompt itself at point of use.
private struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            picker.sourceType = .camera
            picker.cameraCaptureMode = .photo
        } else {
            picker.sourceType = .photoLibrary
        }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage) -> Void

        init(onImage: @escaping (UIImage) -> Void) {
            self.onImage = onImage
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            picker.dismiss(animated: true)
            if let image = info[.originalImage] as? UIImage {
                onImage(image)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
