import SwiftUI
import UIKit

/// Camera-capture + guidance sheet for the appliance helper (design §5).
/// All pipeline logic lives in `ApplianceHelperSession`; this view only
/// renders `session.state` and forwards camera results. Since 2026-09-06
/// the opening (capturing) state also offers the saved-manuals library
/// (`ApplianceManualLibraryView`) — saved guides re-rendered from cache,
/// camera-less and network-free.
///
/// Guidance layout: instead of one crammed overlay on the full photo, each
/// step is its own card — the instruction text up top, then a CROPPED,
/// zoomed close-up of the relevant section with the button circled (a
/// `talkGlowEnd` ring, white under-stroke, step badge) and the button's
/// label beneath it (augmented into the ACTIVE locale's language when the
/// localizer knows the label). Close-ups are pinch-zoomed up to 4×
/// (double-tap resets to 1×).
///
/// The crop rect is a pure function of (normalizedBox, CGImage pixel
/// size) via `ApplianceCropGeometry`; the ring maps through
/// `ApplianceOverlayMapper` on every size change, so there is no stale
/// mapping state on rotation/Dynamic Type. Numerals and label augmentation
/// follow the active locale (`@Environment(\.locale)`, set at the app root
/// from `AppLanguage`) — Devanagari only under a Nepali-active locale.
struct ApplianceHelperView: View {

    @ObservedObject var session: ApplianceHelperSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var showCamera = false
    /// Auto-open the camera once when the sheet appears (the voice turn
    /// already said "show me the appliance"); retakes use the button.
    @State private var didAutoOpenCamera = false
    /// The saved-manuals library (2026-09-06): opened from the capturing
    /// state; rows open manuals as cache-rendered guidance.
    @State private var showManualsLibrary = false
    @State private var manualsModel: ApplianceManualLibraryModel?

    /// Close-up panels are deliberately tall — the photo section is the
    /// point of the step card.
    private static let closeUpHeight: CGFloat = 260

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
            // Auto-open belongs to a live capture session only: an ARMED
            // session (bundled default manuals opened from the library or
            // Settings, 2026-09-07) is already in .guidance and must not
            // pop the camera over its step cards.
            guard !didAutoOpenCamera, session.state == .capturing else { return }
            didAutoOpenCamera = true
            showCamera = true
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker(onImage: { image in
                session.handleCapturedPhoto(image)
            })
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showManualsLibrary) {
            if let model = manualsModel {
                ApplianceManualLibraryView(session: session, model: model)
            }
        }
    }

    // MARK: - Manuals library entry

    private func openManualsLibrary() {
        manualsModel = ApplianceManualLibraryModel(cache: session.cache)
        showManualsLibrary = true
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

            // Saved-manuals entry (2026-09-06): the second way the cache
            // pays off — browse previously saved guides without touching
            // the camera or the network.
            Button {
                openManualsLibrary()
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 24))
                        .foregroundColor(DesignTokens.accent)
                        .frame(width: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("appliance.manual.title")
                            .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                            .foregroundColor(DesignTokens.textPrimary)
                        Text("appliance.manual.openHint")
                            .font(.system(size: DesignTokens.minCaptionPointSize))
                            .foregroundColor(DesignTokens.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(DesignTokens.textSecondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(DesignTokens.setupReminder)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            .padding(.horizontal, 24)
            .padding(.top, 6)
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
                overviewCard(presentation)

                // Camera-era affordances only: a SAVED MANUAL (2026-09-06)
                // is a cache re-render — "take a closer photo" and
                // "retake" make no sense without the camera session.
                if presentation.showCloserPhotoHint && !session.isViewingManual {
                    closerPhotoHint
                }

                stepCards(presentation, image: image)

                if !session.isViewingManual {
                    Button {
                        session.retake()
                    } label: {
                        Label("appliance.retake", systemImage: "camera.rotate.fill")
                            .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                            .foregroundColor(DesignTokens.accent)
                            .frame(minHeight: DesignTokens.minTapTargetSize)
                    }
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

    /// Appliance name + spoken summary (the answer's plain-text anchor;
    /// step detail now lives in the per-step cards below).
    private func overviewCard(_ presentation: ApplianceGuidancePolicy.Presentation) -> some View {
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
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }

    // MARK: - Step cards

    /// One card per step, in order: badge + instruction text, then one
    /// cropped close-up (circled button + label) per grounded control of
    /// that step. Steps without a control stay text-only.
    private func stepCards(_ presentation: ApplianceGuidancePolicy.Presentation,
                           image: UIImage) -> some View {
        let cards = ApplianceStepCardPlanner.build(
            steps: presentation.guidance.steps,
            controls: presentation.visibleControls)
        return ForEach(cards, id: \.number) { card in
            stepCard(card, image: session.bundledStepImages[card.number] ?? image)
        }
    }

    private func stepCard(_ card: ApplianceStepCard, image: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(DesignTokens.accent)
                    Text(stepNumberText(card.number))
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                        .foregroundColor(.white)
                        .accessibilityLabel(Text(stepAccessibilityLabel(card.number)))
                }
                .frame(width: 42, height: 42)
                Text(card.text)
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 9)
                Spacer(minLength: 0)
            }
            ForEach(Array(card.controls.enumerated()), id: \.offset) { _, control in
                controlSection(control, stepNumber: card.number, image: image)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        .accessibilityElement(children: .combine)
    }

    /// The cropped close-up (button circled, pinch-zoomable) plus the
    /// button's label — augmented into the active locale when the
    /// localizer knows the printed English text.
    @ViewBuilder
    private func controlSection(_ control: GroundedControl,
                                stepNumber: Int,
                                image: UIImage) -> some View {
        let display = ApplianceLabelLocalizer.display(for: control.label,
                                                      locale: locale)
        VStack(alignment: .leading, spacing: 10) {
            if let pixelSize = ApplianceCropGeometry.imagePixelSize(image),
               let crop = ApplianceCropGeometry.crop(for: control.normalizedBox,
                                                     imagePixelSize: pixelSize),
               let croppedCG = image.cgImage?.cropping(to: crop.rect) {
                let cropped = UIImage(cgImage: croppedCG,
                                      scale: image.scale,
                                      orientation: image.imageOrientation)
                ZoomableStepImage(image: cropped,
                                  crop: crop,
                                  badgeText: stepNumberText(stepNumber))
                    .frame(height: Self.closeUpHeight)
                    .frame(maxWidth: .infinity)
                    .background(DesignTokens.userBubble)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
                    .accessibilityHidden(true)
            }
            buttonLabel(display)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The button's name under its close-up: the active locale's term when
    /// the localizer knows it, with the printed English kept as a
    /// reference line.
    private func buttonLabel(_ display: ApplianceLabelLocalizer.Display) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(display.primary)
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                .foregroundColor(DesignTokens.textPrimary)
            if let secondary = display.secondary {
                Text(secondary)
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Locale-driven presentation

    /// Numerals and label augmentation follow the ACTIVE locale (the
    /// `.locale` injected at the app root from `AppLanguage`) — Devanagari
    /// only under a Nepali-active session, Western digits otherwise.
    private var isNepaliUI: Bool {
        ApplianceLabelLocalizer.isNepali(locale)
    }

    private func stepNumberText(_ number: Int) -> String {
        isNepaliUI ? DevanagariNumerals.string(number) : "\(number)"
    }

    private func stepAccessibilityLabel(_ number: Int) -> String {
        L10n.fmt("appliance.stepAccessibility", locale: locale, stepNumberText(number))
    }
}

// MARK: - Zoomable step close-up

/// The per-step cropped photo: the crop aspect-fits inside the panel, the
/// ring/badge overlay tracks the control's box, and the whole content
/// layer pinch-zooms 1×–4× with panning while zoomed (double-tap resets
/// to 1×). Zoom transitions animate unless the user has Reduce Motion on
/// (zooming itself still works — only the animation is skipped).
private struct ZoomableStepImage: View {
    /// The cropped region as a `UIImage`.
    let image: UIImage
    /// The crop geometry the ring is placed against.
    let crop: ApplianceCropGeometry.Crop
    /// The step's badge text, already localized (e.g. "१" or "1").
    let badgeText: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Zoom settled between gestures (1 = fit).
    @State private var settledZoom: CGFloat = 1
    /// Pan offset settled between drags.
    @State private var settledPan: CGSize = .zero
    /// In-flight pinch factor (resets to 1 when the gesture ends).
    @GestureState private var pinchFactor: CGFloat = 1
    /// Pan origin for the CURRENT drag (so translations accumulate).
    @State private var panBase: CGSize = .zero

    /// Displayed zoom — clamped by pure `ApplianceZoomGeometry`.
    private var zoom: CGFloat {
        ApplianceZoomGeometry.clampedScale(settledZoom * pinchFactor)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                let displayed = ApplianceOverlayMapper.displayedImageRect(
                    containerSize: geometry.size,
                    imageSize: image.size)
                if displayed.width > 0, displayed.height > 0 {
                    highlightOverlay(displayed: displayed)
                }
            }
            .scaleEffect(zoom)
            .offset(settledPan)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .simultaneousGesture(magnificationGesture(baseSize: geometry.size))
            .simultaneousGesture(dragGesture(baseSize: geometry.size),
                                 including: zoom > 1.001 ? .all : .none)
            .simultaneousGesture(resetGesture,
                                 including: zoom > 1.001 ? .all : .none)
        }
    }

    /// The circled button + step badge, drawn in the crop's own displayed
    /// space (the layer zooms as one, so the ring stays glued to the
    /// button at any zoom). The ring encloses the control's VISIBLE box
    /// (crop ∩ box, so a box that runs past the photo edge never gets an
    /// off-photo center) with a readability floor.
    private func highlightOverlay(displayed: CGRect) -> some View {
        let ringCenter = CGPoint(x: displayed.minX + crop.boxInCrop.midX * displayed.width,
                                 y: displayed.minY + crop.boxInCrop.midY * displayed.height)
        let boxWidth = crop.boxInCrop.width * displayed.width
        let boxHeight = crop.boxInCrop.height * displayed.height
        // Enclosing circle of the visible box; can never exceed the photo.
        let enclosing = 0.5 * CGFloat(hypot(Double(boxWidth), Double(boxHeight))) * 1.15
        let radius = min(max(enclosing, 22), min(displayed.width, displayed.height) / 2)
        return ZStack {
            // White under-stroke keeps the orange ring legible on both
            // dark and busy control panels (don't rely on color alone).
            Circle()
                .stroke(Color.white, lineWidth: 6)
                .frame(width: (radius + 3) * 2, height: (radius + 3) * 2)
                .position(ringCenter)
            Circle()
                .stroke(DesignTokens.talkGlowEnd, lineWidth: 4.5)
                .frame(width: radius * 2, height: radius * 2)
                .position(ringCenter)
            ZStack {
                Circle().fill(DesignTokens.talkGlowEnd)
                Text(badgeText)
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: 32, height: 32)
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .position(x: ringCenter.x + radius * 0.78,
                      y: ringCenter.y - radius * 0.78)
        }
    }

    // MARK: Gestures

    private func magnificationGesture(baseSize: CGSize) -> some Gesture {
        MagnificationGesture()
            .updating($pinchFactor) { value, state, _ in
                state = value
            }
            .onEnded { value in
                settledZoom = ApplianceZoomGeometry.clampedScale(settledZoom * value)
                settlePan(to: ApplianceZoomGeometry.clampedOffset(
                    settledPan, zoom: settledZoom, baseSize: baseSize))
            }
    }

    private func dragGesture(baseSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let proposed = CGSize(width: panBase.width + value.translation.width,
                                      height: panBase.height + value.translation.height)
                settlePan(to: ApplianceZoomGeometry.clampedOffset(
                    proposed, zoom: zoom, baseSize: baseSize))
            }
            .onEnded { _ in
                panBase = settledPan
            }
    }

    /// Double-tap resets the close-up to its 1× fit (and centered).
    private var resetGesture: some Gesture {
        TapGesture(count: 2)
            .onEnded {
                animate {
                    settledZoom = 1
                    settlePan(to: .zero)
                }
            }
    }

    // MARK: Helpers

    /// Reduce Motion (accessibility) skips zoom/pan animations but never
    /// the zoom itself.
    private func animate(_ change: () -> Void) {
        if reduceMotion {
            change()
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                change()
            }
        }
    }

    private func settlePan(to value: CGSize) {
        settledPan = value
        panBase = value
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
