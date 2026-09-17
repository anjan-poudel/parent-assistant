import AVFoundation
import SwiftUI
import UIKit

// T-027 — the full-bleed session view (FR-LCT-001, FR-LCT-022, NFR-LCT-004,
// NFR-LCT-011).
//
// What this file exists to make true:
//
//  1. **The overlay's on-screen home.** `LiveTranslateOverlayView` (T-021) is
//     a pure function of its surface and had no host; this is the host. The
//     view hands it the model's surface — the placements the pipeline measured
//     — so the rects drawn are the rects computed, and the layout the view
//     reports is the layout those rects were computed in.
//
//  2. **This view is the only place that knows SwiftUI.** The pipeline has no
//     geometry of its own, so the chrome the overlay must avoid (the close
//     control, the indicator, the overlay's own control strip) is measured
//     here and pushed to the model, which forwards it. The view holds no
//     session state of its own: everything it renders comes from the model.
//
//  3. **The chrome is composed around the overlay, not inside it.** The
//     consent prompt (T-015), the cloud indicator (T-016) and the camera
//     permission card (T-008) are the session's, rendered over the overlay;
//     the overlay's own always-show-original control (T-022) stays where
//     T-021 put it, in the strip the overlay reserves. Nothing here draws a
//     second close, a second toggle or a second indicator.
//
//  4. **One obvious exit.** The close control is a real button at the app's
//     minimum tap target, labelled in the active language from the shipped
//     `common.close` string — the same one the rest of the app's sheets use.
//
//  5. **Lifecycle is here, and only here.** `onAppear` starts the session
//     (idempotent — a re-entrant appear cannot start a second one), the
//     background/foreground pair pauses and resumes frame processing through
//     the model, and disappearing closes: capture stops, the microphone is
//     released, speech is drained.
//
//  6. **A frozen frame is drawn here, and it lands on the results card
//     (T-033; owner UX rework, 2026-09-17).** The preview branch draws the held
//     picture in place of the camera layer — the letterbox the placements are
//     mapped through is the frozen frame's own — and the capture control sits
//     in the same reserved strip as the exit and the indicator. While a frame
//     is held, `LiveTranslateResultsCardView` is drawn under that strip
//     *instead of* the overlay: no bubbles over the picture, nothing moving,
//     one scrollable column of large type whose rows speak on tap. The control
//     in the strip is the way back to live ("Go live again"). The view keeps
//     no freeze state: it reads `model.frozenFrameImage`, `model.surface` and
//     `model.snapshotSurface`, exactly as it reads the live ones.

struct LiveTranslateView: View {

    @StateObject private var model: LiveTranslateSessionModel
    @Environment(\.dismiss) private var dismiss

    init(dependencies: LiveTranslateSessionDependencies) {
        _model = StateObject(wrappedValue: LiveTranslateSessionModel(dependencies: dependencies))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black

                preview

                // The live overlay, and *only* the live overlay: while a frame
                // is held the card below is the reading surface, so no box is
                // drawn over the picture at all. Card mode has no moving parts
                // by construction, not by an animation being switched off.
                if !model.isFrozen {
                    LiveTranslateOverlayView(
                        surface: model.surface,
                        onTapRegion: { model.tapRegion($0) },
                        onSetAlwaysShowOriginal: { model.setAlwaysShowOriginal($0) })
                }

                chrome(in: proxy)

                // The consent prompt is presented over everything (it is the
                // one thing that must not be missed) and the permission card
                // explains before the system prompt appears.
                consentPrompt

                permissionCard
            }
            .onAppear {
                reportLayout(proxy)
                Task { await model.start() }
            }
            .onChange(of: proxy.size) { _ in reportLayout(proxy) }
        }
        .ignoresSafeArea()
        .onDisappear {
            // Closing twice is a no-op (`LiveTranslateSessionModel.close`),
            // which is what makes the close control and the sheet's own
            // dismissal the same teardown.
            Task { await model.close() }
        }
    }

    // MARK: - The preview

    @ViewBuilder
    private var preview: some View {
        if let image = model.frozenFrameImage {
            // The frozen picture (T-033), drawn the way the live preview draws
            // the camera: the whole frame, aspect-fit in the container, so the
            // letterbox the callouts were measured through is the letterbox on
            // screen. Decorative — the overlay is what describes the frame —
            // and read-only: nothing here can capture, save or share it.
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
        } else if let layer = model.previewLayer {
            LiveTranslatePreviewHost(layer: layer)
                .accessibilityHidden(true)
        } else {
            Color.black
        }
    }

    // MARK: - Chrome

    @ViewBuilder
    private func chrome(in proxy: GeometryProxy) -> some View {
        VStack {
            ZStack {
                HStack(alignment: .top) {
                    closeControl
                    Spacer(minLength: DesignTokens.interElementSpacing)
                    CloudActivityIndicatorView(surface: model.cloudIndicator)
                }
                // Centred, so the freeze is one tap away in the middle of the
                // strip and cannot be confused with the exit on the leading
                // edge or the indicator on the trailing one.
                snapshotControl
            }
            // While a frame is held, the card is the surface — there are no
            // bubbles over the picture in this mode at all (see `preview`'s
            // frozen branch and `resultsCard`) — and the control in the strip
            // above is what takes the elder back to the live view.
            if model.isFrozen {
                resultsCard(in: proxy)
            }
            Spacer()
        }
        .padding(DesignTokens.interElementSpacing)
        .padding(.top, proxy.safeAreaInsets.top)
        .padding(.leading, proxy.safeAreaInsets.leading)
        .padding(.trailing, proxy.safeAreaInsets.trailing)
    }

    /// The frozen frame's reading surface (owner UX rework, 2026-09-17): the
    /// snapshot's *results card*, over the held picture.
    ///
    /// Shown in place of the bubbles rather than beside them — the elder came
    /// here to read, and a box floating over a still picture is exactly what
    /// the owner's device feedback rejected. It is bounded to a share of the
    /// container so the held frame stays visible behind it, and it is a pure
    /// function of the model: one row per recognized string the held frame
    /// carries, whether or not a box could be measured for it, and tapping a
    /// row speaks the very region that row names.
    private func resultsCard(in proxy: GeometryProxy) -> some View {
        LiveTranslateResultsCardView(
            surface: model.resultsCard,
            onSpeak: { model.tapRegion($0) })
            .frame(maxHeight: proxy.size.height * Self.resultsCardHeightFraction)
            .padding(.top, DesignTokens.interElementSpacing)
    }

    /// The results card's share of the container's height: enough for a
    /// readable list of rows, short enough that the held picture is still
    /// there behind it — the card is *over* the frame, not instead of it.
    static let resultsCardHeightFraction: CGFloat = 0.7

    /// The capture control (T-033). It lives in this strip — the one
    /// `topChromeRects` reserves and the placement is told to keep clear — so
    /// a callout cannot land on it. A failed start has T-008's own surface and
    /// gets no freeze control; while the camera is coming up the control is
    /// drawn disabled rather than appearing late.
    @ViewBuilder
    private var snapshotControl: some View {
        if model.snapshotSurface.isPresented {
            LiveTranslateSnapshotControl(surface: model.snapshotSurface) {
                model.toggleSnapshot()
            }
        }
    }

    private var closeControl: some View {
        Button {
            Task {
                await model.close()
                dismiss()
            }
        } label: {
            HStack(spacing: DesignTokens.interElementSpacing) {
                Image(systemName: Self.closeSymbolName)
                Text(L10n.str(Self.closeKey, locale: model.locale))
                    // Session chrome, not overlay text: the app's own
                    // dynamic-type-aware font, so the exit grows with the
                    // elder's text size (NFR-LCT-011). The overlay's text
                    // metrics are for text the placement measures, which this
                    // is not.
                    .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(DesignTokens.textPrimary)
            .padding(.horizontal, DesignTokens.interElementSpacing)
            .frame(minWidth: DesignTokens.minTapTargetSize,
                   minHeight: DesignTokens.minTapTargetSize)
            .background(DesignTokens.card)
            .clipShape(Capsule())
        }
        .accessibilityIdentifier("livetranslate.close")
    }

    /// The shipped close string, reused: T-005's own inventory test pins this
    /// key as the feature's close copy, so the session's exit says what every
    /// other exit in the app says.
    static let closeKey = "common.close"
    static let closeSymbolName = "xmark"

    // MARK: - Consent and permission

    @ViewBuilder
    private var consentPrompt: some View {
        if model.consent.isPromptPresented {
            ZStack {
                Color.black.opacity(0.45)
                ConsentPromptView(surface: model.consent.promptSurface,
                                  onGrant: { model.grantCloudConsent() },
                                  onDecline: { model.declineCloudConsent() })
                    .padding(DesignTokens.interElementSpacing)
            }
        }
    }

    @ViewBuilder
    private var permissionCard: some View {
        if let state = model.cameraSurface {
            CameraPermissionView(surface: CameraPermissionSurface(state: state, locale: model.locale),
                                 onContinue: { Task { await model.continueFromCameraExplanation() } })
                .padding(DesignTokens.interElementSpacing)
        }
    }

    // MARK: - Layout

    /// Reports the geometry the pipeline cannot derive: the container, the safe
    /// area and the chrome a callout must not land under. Called on appear and
    /// on every size change (rotation, a keyboard, a split view); an unchanged
    /// layout is dropped by the model.
    private func reportLayout(_ proxy: GeometryProxy) {
        let insets = proxy.safeAreaInsets
        let width = max(0, proxy.size.width - insets.leading - insets.trailing)
        let height = max(0, proxy.size.height - insets.top - insets.bottom)
        let safeArea = CGRect(x: insets.leading, y: insets.top, width: width, height: height)
        model.updateLayout(containerSize: proxy.size,
                           safeArea: safeArea,
                           occupiedRects: Self.occupiedRects(containerSize: proxy.size))
    }

    /// The strips the overlay must not draw under: the overlay's own reserved
    /// strip (T-021's `chromeRects`, where its always-show-original control
    /// lives) and this view's top strip (the close control and the indicator).
    ///
    /// Both are stated as their own layout arithmetic rather than measured
    /// after the fact: the placement needs the rects before the controls are
    /// laid out, and a conservative reservation is the honest answer. The
    /// reserved heights are the same ones the controls are given — the app's
    /// minimum tap target plus its spacing around it — so a control that grows
    /// to a legal size cannot outgrow its reservation.
    static func occupiedRects(containerSize: CGSize) -> [CGRect] {
        LiveTranslateOverlaySurface.chromeRects(containerSize: containerSize)
            + topChromeRects(containerSize: containerSize)
    }

    /// This view's own strip: the close control on the leading edge and the
    /// cloud indicator on the trailing edge, both in the safe area's top
    /// inset. Full width, because either control can be the wide one
    /// (Devanagari at a large text size is not narrow).
    static func topChromeRects(containerSize: CGSize) -> [CGRect] {
        let height = DesignTokens.minTapTargetSize + 2 * DesignTokens.interElementSpacing
        guard containerSize.width > 0, containerSize.height > height else { return [] }
        return [CGRect(x: 0, y: 0, width: containerSize.width, height: height)]
    }
}

/// The frozen frame as a list to read (owner UX rework, 2026-09-17).
///
/// The opposite of the overlay, deliberately. The overlay is the *glance*
/// surface — a few opaque boxes standing where the text stood — and this is
/// the *reading* surface: no boxes over the picture, no motion, one scrollable
/// column whose rows are the app's body size with the original underneath, and
/// every row a real tap target that speaks through the same path the overlay's
/// bubbles use. It is a pure function of its surface, so what it lists is
/// exactly what was placed, in the order the placement put it in (reading
/// order, top to bottom) — and a frame with nothing on it says so in words
/// rather than showing an empty list.
struct LiveTranslateResultsCardView: View {

    let surface: LiveTranslateResultsCardSurface
    /// Tap-to-hear (C12), on the held frame's own placements: the row hands
    /// back the region it was built from.
    let onSpeak: (TextRegionStabilizer.RegionIdentity) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: DesignTokens.interElementSpacing) {
                ForEach(surface.rows) { row in
                    self.row(row)
                }
                if surface.isEmpty {
                    emptyState
                }
            }
            .padding(DesignTokens.interElementSpacing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        .accessibilityIdentifier("livetranslate.results.card")
    }

    /// The calm sentence for a held frame with no text on it. The same catalog
    /// line the overlay's empty state uses: one situation, one sentence.
    private var emptyState: some View {
        Text(surface.emptyHint)
            .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize))
            .foregroundColor(DesignTokens.textPrimary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(DesignTokens.interElementSpacing * 2)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("livetranslate.results.card.empty")
    }

    /// One row. A row with a translation to hear is a button; one without is
    /// the same content as text, not a button that does nothing.
    @ViewBuilder
    private func row(_ row: LiveTranslateResultsCardSurface.Row) -> some View {
        if row.speaksTranslation {
            Button {
                onSpeak(row.regionID)
            } label: {
                rowContent(row).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(row.translation))
            .accessibilityValue(Text(row.source ?? ""))
            .accessibilityIdentifier("livetranslate.results.row.\(row.regionID.rawValue)")
        } else {
            rowContent(row)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(row.translation))
                .accessibilityValue(Text(row.source ?? ""))
                .accessibilityIdentifier("livetranslate.results.row.\(row.regionID.rawValue)")
        }
    }

    /// The row's content: the translation large, the text it came from small
    /// beneath it, and — for a row that can speak — the glyph that says so.
    /// The tap target is the token's minimum in both directions; the type is
    /// the token table's body and caption floors, never a literal.
    private func rowContent(_ row: LiveTranslateResultsCardSurface.Row) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.interElementSpacing) {
            VStack(alignment: .leading, spacing: DesignTokens.interElementSpacing / 2) {
                HStack(alignment: .firstTextBaseline,
                       spacing: DesignTokens.interElementSpacing / 2) {
                    if let symbol = row.symbolName {
                        Image(systemName: symbol)
                            .foregroundColor(DesignTokens.textSecondary)
                    }
                    Text(row.translation)
                        .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize,
                                                    weight: .semibold))
                        .foregroundColor(DesignTokens.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let source = row.source, !source.isEmpty {
                    Text(source)
                        .font(DesignTokens.warmFont(size: DesignTokens.minCaptionPointSize))
                        .foregroundColor(DesignTokens.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if row.speaksTranslation {
                Image(systemName: Self.speakSymbolName)
                    .foregroundColor(DesignTokens.accent)
            }
        }
        .padding(DesignTokens.interElementSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minWidth: DesignTokens.minTapTargetSize,
               minHeight: DesignTokens.minTapTargetSize)
        .background(DesignTokens.background)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
    }

    /// The hear-this glyph. An SF Symbol name is a system identifier, not
    /// user-visible copy, so it is a constant here.
    static let speakSymbolName = "speaker.wave.2.fill"
}

/// The camera preview, hosted.
///
/// The layer is the session's own `AVCaptureVideoPreviewLayer` (T-006 builds it
/// over the capture session and sets the video gravity), so the aspect the
/// placement maps through — `resizeAspect` over the frame's pixel size — is the
/// aspect the elder sees. The host never configures capture: it lays a layer
/// out and nothing else.
struct LiveTranslatePreviewHost: UIViewRepresentable {

    let layer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.layer.addSublayer(layer)
        view.previewLayer = layer
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.layoutPreviewLayer()
    }

    /// The container whose own layout pass drives the layer's frame — a
    /// `UIView` whose sublayer is sized in `layoutSubviews`, so the preview
    /// follows a rotation without the SwiftUI side scheduling anything.
    final class PreviewView: UIView {
        var previewLayer: AVCaptureVideoPreviewLayer?

        override func layoutSubviews() {
            super.layoutSubviews()
            layoutPreviewLayer()
        }

        func layoutPreviewLayer() {
            guard let previewLayer, window != nil || superview != nil else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            CATransaction.commit()
        }
    }
}
