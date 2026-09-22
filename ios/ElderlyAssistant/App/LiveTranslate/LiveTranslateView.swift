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
//
//  7. **The elder can zoom, and tap where the camera should look (owner report,
//     2026-09-17).** A pinch on the picture and two large buttons either side
//     of the factor the elder is at; the number between them is what the system
//     camera would print for the same lens. Tapping the picture focuses there
//     — the layer converts the tap through the aspect fit, so what is touched
//     is what is focused — and the lock beside the buttons holds focus where it
//     is. The gesture and the buttons carry no *words*: the readout is a
//     numeral ("1.5×") and the controls are system symbols, because the
//     feature's copy is a pinned catalog inventory (`LiveTranslateCopyTests`)
//     and a sentence per reachable zoom factor is not a sentence to translate.
//     All of it is observation: the view calls the session's zoom surface and
//     renders what the **device** reported back.
//
//  8. **The elder can move the window they are looking through (owner report,
//     2026-09-18: "I expected pinch zoom and panning").** Once the picture is
//     zoomed past the whole frame, one finger drags the visible region and the
//     pinch zooms *toward the fingers* rather than the middle of the glass.
//     Both are the same fact — the camera has a **window** into its own frame,
//     and the elder moves and resizes it — so the view holds one map for it
//     (`LiveCameraPresentation`) and every consumer of the picture reads that
//     map: the preview layer is drawn through it (`PreviewView`'s transform),
//     the overlay's boxes are placed through it, and the recognition pass crops
//     to it. Gluing those together is the point: a bubble drawn over a sign
//     stays over the sign while the elder zooms into it. The window is the
//     *display's*, not the sensor's — the zoom itself stays the lens's, so the
//     OCR pass still reads sensor pixels, cropped rather than magnified.

struct LiveTranslateView: View {

    @StateObject private var model: LiveTranslateSessionModel
    /// The zoom and focus surface (owner report, 2026-09-17). Observed rather
    /// than owned: the session owns it — it is the object that talks to the
    /// running device — and the view is one of its readers. Read on the main
    /// thread, like every other surface here.
    @ObservedObject private var zoom: LiveCameraZoomSurface
    @Environment(\.dismiss) private var dismiss

    init(dependencies: LiveTranslateSessionDependencies) {
        _model = StateObject(wrappedValue: LiveTranslateSessionModel(dependencies: dependencies))
        _zoom = ObservedObject(wrappedValue: dependencies.camera.zoomSurface)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black

                preview(in: proxy)

                // The live overlay, and *only* the live overlay: while a frame
                // is held the card below is the reading surface, so no box is
                // drawn over the picture at all. Card mode has no moving parts
                // by construction, not by an animation being switched off.
                if !model.isFrozen {
                    LiveTranslateOverlayView(
                        surface: model.surface,
                        onTapRegion: { model.tapRegion($0) },
                        onSetAlwaysShowOriginal: { model.setAlwaysShowOriginal($0) },
                        // Extract mode's two touch paths (owner verdict,
                        // 2026-09-18): a tap on a block asks for that block's
                        // translation, and the chrome's toggle asks for the
                        // translated view (or back to extract mode).
                        onTranslateRegion: { model.translateRegion($0) },
                        onSetTranslateAll: { model.setExtractMode(!$0) },
                        // [POINT-ASK] The tap box + chip, drawn through the
                        // same presentation the picture is drawn with, with
                        // the chip's tap routed to the hosted session. Nil
                        // surface (no point-ask wiring) draws nothing new.
                        pointAsk: model.pointAsk?.overlaySurface,
                        presentation: presentation(in: proxy),
                        onPointAskChipTap: { model.pointAsk?.chipTapped() },
                        // [FOCUS-CAPTURE] The anchored box's two actions
                        // (Workstream B): "What is it?" above, and here the
                        // elder's "read that" — the touch half of the spoken
                        // "translate here", routed to the same call the words
                        // make, so the two cannot mean different things.
                        //
                        // The box is passed as a *normalized* rect against the
                        // frame in hand (`.null` pixel rect), because that is
                        // what the box is: a place on the picture the elder is
                        // looking at, drawn through the same live presentation
                        // mapping as every other box. A pixel rect measured when
                        // the anchor was made would be a rect from an older
                        // frame, which is the stale-rect crop the focus path
                        // exists to avoid (`translateFocusedRegion`'s
                        // `measuredOn`).
                        onPointAskTranslateTap: {
                            guard let target = model.pointAsk?.anchoredTarget else { return }
                            model.translateFocusedRegion(box: target.box,
                                                         pixelRect: .null,
                                                         measuredOn: model.anchoredFrame)
                        },
                        // The host's own insets (review finding 7): this is
                        // the reader that owns the `.ignoresSafeArea()` the
                        // whole surface is drawn under, so it is the one that
                        // can say where the glass stops being usable.
                        safeAreaBottomInset: proxy.safeAreaInsets.bottom)
                }

                chrome(in: proxy)

                // [FOCUS-CAPTURE] The focused read (Workstream B), over the
                // live surface: the elder pointed at one thing and asked for
                // *that*, so the crop and its reading are what is on screen —
                // not the live scene with a box drawn on it. It is drawn above
                // the chrome (its own back control is the way out, and the
                // zoom and capture controls belong to a live picture that is no
                // longer the subject) and below the two prompts beneath it,
                // which must never be hidden: a focused read can reach the
                // consent question, and the question is the one thing that
                // cannot wait.
                if let capture = model.focusedCapture {
                    LiveTranslateFocusResultView(
                        capture: capture,
                        locale: model.locale,
                        // The session's own numbers, not the shipped default:
                        // a suite that drives a session with its own config
                        // gets the layout that config describes.
                        rule: model.focusRule,
                        safeAreaInsets: proxy.safeAreaInsets,
                        // **The crop's own placements** (review finding 1).
                        // `tapRegion` reads the *live* publication, and while a
                        // focused read is up that is a different picture with
                        // different rows: the id the row handed back belongs to
                        // this crop, so resolving it against the live picture
                        // found nothing (or, worse, found a live region that
                        // happened to share the id) and spoke the wrong text.
                        // The focused surface's taps resolve against the
                        // capture's publication, exactly as the frozen card's
                        // resolve against the held frame's.
                        onSpeak: { model.tapFocusedRegion($0) },
                        onReturnToLive: { model.returnToLive() })
                }

                // The consent prompt is presented over everything (it is the
                // one thing that must not be missed) and the permission card
                // explains before the system prompt appears.
                consentPrompt

                // [POINT-ASK] The point-ask consent sheet, over everything:
                // the one decision that may let a crop leave the phone.
                pointAskConsentPrompt

                permissionCard
            }
            .onAppear {
                reportLayout(proxy)
                Task { await model.start() }
            }
            .onChange(of: proxy.size) { _ in reportLayout(proxy) }
            // The window changed (a pinch, a drag, the ± buttons, a thaw) and
            // the placement must be told before the next surface is drawn: the
            // rects the pipeline measured were measured through the *old*
            // window, and the view is the only reader that knows both. The
            // crop is `Equatable`, so a render that did not move anything
            // costs one comparison and no relayout.
            .onChange(of: zoom.model.crop) { _ in reportLayout(proxy) }
            // The picture's own correction changed, so the boxes' window did
            // too: same reason, same relayout, and `FrameStabilization` is
            // `Equatable` so a still hand — the answer frame after frame — costs
            // one comparison (owner device verdict, 2026-09-18).
            .onChange(of: model.frameStabilization) { _ in reportLayout(proxy) }
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
    private func preview(in proxy: GeometryProxy) -> some View {
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
            // The gestures live on the picture, and only on the picture: the
            // overlay above handles a tap that lands on one of its boxes, and
            // a tap that lands on the picture is the elder pointing the camera
            // at something (see `LiveTranslatePreviewHost`). Decorative to
            // VoiceOver — the overlay is what describes the frame — and the
            // zoom controls are real controls with their own identifiers.
            LiveTranslatePreviewHost(layer: layer,
                                     presentation: presentation(in: proxy),
                                     isWindowed: !zoom.model.crop.isWhole,
                                     onPinch: { zoom.pinch(to: Double($0), at: $1) },
                                     onPinchEnded: { zoom.pinchEnded() },
                                     onPan: { zoom.pan(to: $0) },
                                     onPanEnded: { zoom.panEnded() },
                                     onFocusTap: { zoom.focus(atDevicePoint: $0) },
                                     // [POINT-ASK] The same tap also anchors
                                     // the point-ask box: one gesture, two
                                     // intents — focus *and* point. The
                                     // hosted session resolves the frame
                                     // point (the picture's coordinates,
                                     // not the device's).
                                     onPointAskTap: { framePoint in
                                         model.pointAsk?.handleTap(
                                             atNormalizedPoint: framePoint)
                                     })
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
                    // [POINT-ASK] The visible cloud indicator for the
                    // point-ask tier: on while a crop may be leaving the
                    // phone (design §5). Beside the live-translate
                    // indicator — the elder reads both the same way.
                    if model.pointAsk?.cloudIndicatorActive == true {
                        PointAskCloudIndicatorView(locale: model.locale)
                    }
                }
                // Centred, so the freeze is one tap away in the middle of the
                // strip and cannot be confused with the exit on the leading
                // edge or the indicator on the trailing one.
                snapshotControl
            }
            // The warden's notice, when there is one: a brief status under the
            // strip the elder's eye is already on. Absent for every moment but
            // two, and for at most `wardenNoticeDismissSeconds` when it is
            // there — the model owns that window, so this is a read and
            // nothing else.
            //
            // Deliberately *not* folded into the layout the placement is told
            // to avoid (`occupiedRects`): that reservation is measured once
            // per container size, precisely so the boxes never re-place for a
            // reason the elder did not cause, and a band that appeared and
            // disappeared every time a model loaded would move every callout
            // near the top twice per notice. A callout may therefore sit under
            // a notice for those few seconds, which is the smaller of the two
            // evils by a wide margin (the owner's standing device complaint is
            // that boxes jump).
            wardenNotice
            // While a frame is held, the card is the surface — there are no
            // bubbles over the picture in this mode at all (see `preview`'s
            // frozen branch and `resultsCard`) — and the control in the strip
            // above is what takes the elder back to the live view.
            if model.isFrozen {
                resultsCard(in: proxy)
            }
            Spacer()
            // The live controls, out of the way of a thumb holding the phone
            // over a package: the bottom of the screen, on the band directly
            // above the overlay's own control strip. Not drawn while a frame is
            // held — the picture is still there, and a still picture is not
            // something to zoom into.
            //
            // The lift is the overlay's own strip's height, asked of the
            // overlay's own arithmetic: T-021 pinned the always-show-original
            // toggle to the bottom leading edge, so a zoom control drawn at the
            // same edge would share its corner and its touch.
            if !model.isFrozen {
                zoomControls
                    .padding(.bottom, Self.overlayStripHeight(containerSize: proxy.size))
            }
        }
        .padding(DesignTokens.interElementSpacing)
        .padding(.top, proxy.safeAreaInsets.top)
        .padding(.bottom, proxy.safeAreaInsets.bottom)
        .padding(.leading, proxy.safeAreaInsets.leading)
        .padding(.trailing, proxy.safeAreaInsets.trailing)
    }

    /// The warden's notice (owner directive, 2026-09-19). Nil for every
    /// moment but two, and read straight off the model's surface: the view
    /// has no notice state of its own, no timer for one and no way to dismiss
    /// one, because the session owns all three.
    @ViewBuilder
    private var wardenNotice: some View {
        if let surface = model.wardenNoticeSurface {
            LiveTranslateWardenNoticeBanner(surface: surface)
        }
    }

    // MARK: - Zoom and focus (owner report, 2026-09-17)

    /// The live controls: one press either side of the factor the elder is at,
    /// the factor itself between them, and the focus lock at the trailing edge.
    ///
    /// Sized from the token table (a control is never below the app's minimum
    /// tap target, and the +/− pair is drawn larger still — 52 pt — because a
    /// thumb aiming at a phone held over a package is not precise), and placed
    /// where the overlay is told to keep clear (`zoomChromeRects`).
    private var zoomControls: some View {
        HStack(spacing: DesignTokens.interElementSpacing) {
            zoomStepControl(.wider)
            zoomReadout
            zoomStepControl(.closer)
            Spacer(minLength: DesignTokens.interElementSpacing)
            focusLockControl
        }
    }

    /// A press of **−** (`direction: .wider`: a shorter lens, a wider view) or
    /// **+** (`.closer`). Drawn disabled at the end of the range rather than
    /// hidden, so the control the elder has learned stays where it is.
    private func zoomStepControl(_ direction: ZoomStepDirection) -> some View {
        let isCloser = direction == .closer
        return Button {
            zoom.zoom(direction)
        } label: {
            Image(systemName: isCloser ? Self.zoomInSymbolName : Self.zoomOutSymbolName)
                .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize, weight: .semibold))
                .foregroundColor(DesignTokens.textPrimary)
                .frame(width: Self.zoomControlDiameter, height: Self.zoomControlDiameter)
                .background(DesignTokens.card)
                .clipShape(Circle())
        }
        .disabled(isCloser ? !zoom.model.canZoomCloser : !zoom.model.canZoomWider)
        .accessibilityIdentifier(isCloser ? Self.zoomInIdentifier : Self.zoomOutIdentifier)
    }

    /// The factor, as the elder reads it — "1×", "1.5×", "2.5×".
    ///
    /// A numeral and a multiplication sign, in the device's display space, so
    /// the number matches what the system camera would show for the same lens.
    /// No words, deliberately (see the file's header): the catalog inventory is
    /// pinned, and arithmetic on session state is not copy.
    private var zoomReadout: some View {
        Text(zoom.model.label)
            .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize, weight: .semibold))
            .monospacedDigit()
            .foregroundColor(DesignTokens.textPrimary)
            .padding(.horizontal, DesignTokens.interElementSpacing)
            .frame(minWidth: Self.zoomControlDiameter, minHeight: Self.zoomControlDiameter)
            .background(DesignTokens.card)
            .clipShape(Capsule())
            .accessibilityIdentifier(Self.zoomFactorIdentifier)
    }

    /// Holds focus at its current lens position, or lets it search again. The
    /// glyph is the state as well as the control (a closed padlock in the
    /// accent colour is focus held), which is how the system camera's own lock
    /// reads.
    private var focusLockControl: some View {
        Button {
            zoom.toggleFocusLock()
        } label: {
            Image(systemName: zoom.isFocusLocked ? Self.focusLockedSymbolName
                                                 : Self.focusUnlockedSymbolName)
                .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize, weight: .semibold))
                .foregroundColor(zoom.isFocusLocked ? DesignTokens.accent : DesignTokens.textPrimary)
                .frame(width: Self.zoomControlDiameter, height: Self.zoomControlDiameter)
                .background(DesignTokens.card)
                .clipShape(Circle())
        }
        .accessibilityIdentifier(Self.focusLockIdentifier)
    }

    /// A control's drawn size: the app's minimum tap target plus its spacing —
    /// the one relationship the reserved strip is computed from, so a control
    /// can never outgrow its reservation.
    static let zoomControlDiameter = DesignTokens.minTapTargetSize + DesignTokens.interElementSpacing

    /// SF Symbol names, not copy: system identifiers, like the close control's.
    static let zoomInSymbolName = "plus.magnifyingglass"
    static let zoomOutSymbolName = "minus.magnifyingglass"
    static let focusLockedSymbolName = "lock.fill"
    static let focusUnlockedSymbolName = "lock.open"

    static let zoomInIdentifier = "livetranslate.zoom.in"
    static let zoomOutIdentifier = "livetranslate.zoom.out"
    static let zoomFactorIdentifier = "livetranslate.zoom.factor"
    static let focusLockIdentifier = "livetranslate.focus.lock"

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

    /// [POINT-ASK] The point-ask consent sheet, presented by the hosted
    /// session at its first cloud need — the same "over everything, no
    /// auto-dismiss" surface the live-translate prompt uses, with the
    /// point-ask disclosure copy.
    @ViewBuilder
    private var pointAskConsentPrompt: some View {
        if let pointAsk = model.pointAsk, pointAsk.isConsentPromptPresented {
            ZStack {
                Color.black.opacity(0.45)
                PointAskConsentPromptView(surface: pointAsk.consentSurface,
                                          onGrant: { pointAsk.grantCloudConsent() },
                                          onDecline: { pointAsk.declineCloudConsent() })
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

    /// The window the picture is drawn through, at the size the camera is
    /// delivering — the map every gesture on the picture is read through, and
    /// the map the preview layer is transformed by.
    ///
    /// The picture rect is the app's own aspect-fit arithmetic
    /// (`ApplianceOverlayMapper.displayedImageRect`), over the frame the camera
    /// reported, which is the same rect the placement maps its boxes into
    /// (`framePixelSize` is stamped from the frames themselves, so the view
    /// draws the aspect the pipeline measured). One map, two readers: a box on
    /// screen and the picture point under the elder's finger are computed from
    /// the same numbers, which is what keeps a bubble glued to what it names
    /// while the elder zooms and pans. Before the first frame arrives the size
    /// is zero, `isUsable` is false and the transform is the identity — the
    /// layer is simply the full container, which is what it was before any of
    /// this existed.
    /// The window the picture is *drawn* through: the elder's own window with the
    /// frame's stabilization composed into it (owner device verdict, 2026-09-18:
    /// *"STABILISE THE IMAGE FIRST"*).
    ///
    /// One composition, in the one place a presentation is built, and that is
    /// the whole of what makes the picture still *and* the boxes glued to it:
    /// the layer transform, the gesture conversions and
    /// `LiveOverlayPlacement.screenRect(for:...)` are all functions of this
    /// crop, so the displayed image and the rect a box is drawn in cannot
    /// disagree — the correction moves the picture and the box by the same
    /// amount, by construction, not by a second transform kept in step. The
    /// zoom model's own window is untouched: the stabilization is not the
    /// elder's gesture and never becomes part of the zoom's state (a pinch
    /// still anchors on the window the elder's fingers are moving).
    private func displayedCrop() -> LiveCameraCrop {
        zoom.model.crop.stabilized(by: model.frameStabilization)
    }

    private func presentation(in proxy: GeometryProxy) -> LiveCameraPresentation {
        LiveCameraPresentation(crop: displayedCrop(),
                               pictureRect: ApplianceOverlayMapper.displayedImageRect(
                                   containerSize: proxy.size, imageSize: model.framePixelSize))
    }

    /// Reports the geometry the pipeline cannot derive: the container, the safe
    /// area, the chrome a callout must not land under, and the window the
    /// picture is being read through. Called on appear, on every size change
    /// (rotation, a keyboard, a split view) and on every change of the window
    /// (a pinch, a drag, the ± buttons, a thaw); an unchanged layout is dropped
    /// by the model.
    private func reportLayout(_ proxy: GeometryProxy) {
        let insets = proxy.safeAreaInsets
        let width = max(0, proxy.size.width - insets.leading - insets.trailing)
        let height = max(0, proxy.size.height - insets.top - insets.bottom)
        let safeArea = CGRect(x: insets.leading, y: insets.top, width: width, height: height)
        // The obstacles a callout must not land under: the fixed strips, plus
        // the zoom controls' own strip at the bottom. Composed here rather than
        // inside `occupiedRects`, which names the two strips that are always
        // reserved whatever the session is doing — the zoom strip is composed
        // in because its height depends on the safe area this function has.
        // The crop reported is the **displayed** one — the elder's window with
        // the picture's stabilization composed in — because the placement maps
        // its boxes through it and the boxes must land on the picture as it is
        // drawn (owner device verdict, 2026-09-18: "overlay text on top of the
        // original text"). The rects the pipeline measured were measured through
        // this same window, and the view is the only reader that knows both.
        model.updateLayout(containerSize: proxy.size,
                           safeArea: safeArea,
                           occupiedRects: Self.occupiedRects(containerSize: proxy.size,
                                                            bottomInset: insets.bottom),
                           crop: displayedCrop())
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

    /// `occupiedRects` plus the bottom strip the zoom controls stand in. A
    /// separate function so the two always-reserved strips stay one arithmetic
    /// (`occupiedRects`, which the overlay's own tests pin) and the conditional
    /// strip is a decision made at the call site.
    static func occupiedRects(containerSize: CGSize, bottomInset: CGFloat) -> [CGRect] {
        occupiedRects(containerSize: containerSize)
            + zoomChromeRects(containerSize: containerSize, bottomInset: bottomInset)
    }

    /// The zoom controls' strip: a control and its spacing around it, in the
    /// band directly **above the overlay's own strip** — never in it, because
    /// that strip's bottom-leading corner is T-021's always-show-original
    /// toggle.
    ///
    /// The safe area's own bottom inset is part of the band: the chrome is laid
    /// out inside the safe area (the VStack's own padding), so the band the
    /// controls land in moves up with it. The height of the strip below is the
    /// overlay's own arithmetic, taken from `LiveTranslateOverlaySurface`
    /// rather than copied.
    ///
    /// Reserved even while a frame is held and the controls are not drawn: the
    /// session measures a layout once per size, and a reservation that appeared
    /// and disappeared with the freeze state would be a strip the placement was
    /// told about at a different moment than the one it drew in.
    static func zoomChromeRects(containerSize: CGSize, bottomInset: CGFloat = 0) -> [CGRect] {
        let height = zoomControlDiameter + 2 * DesignTokens.interElementSpacing
        let y = containerSize.height - max(0, bottomInset)
            - overlayStripHeight(containerSize: containerSize) - height
        guard containerSize.width > 0, containerSize.height > height, y >= 0 else { return [] }
        return [CGRect(x: 0, y: y, width: containerSize.width, height: height)]
    }

    /// The height of the overlay's own reserved strip, which the zoom controls
    /// stand on. Asked of `LiveTranslateOverlaySurface.chromeRects` — the
    /// function that owns that arithmetic — so the two bands cannot drift
    /// apart and start sharing a corner.
    static func overlayStripHeight(containerSize: CGSize) -> CGFloat {
        LiveTranslateOverlaySurface.chromeRects(containerSize: containerSize).first?.height ?? 0
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

/// The warden's two moments as the banner renders them (owner directive,
/// 2026-09-19: "keep the user in the loop so they don't wonder about the
/// silences").
///
/// One notice, one sentence, resolved from the catalog in the active language
/// — the same shape every other surface in this feature has
/// (`TranslateAllSurface`, `AlwaysShowOriginalSurface`). The sentence itself
/// is never spelled here or anywhere else in the render path:
/// `LocalBrainWardenNotice.copyKey` is the one place a moment names its
/// catalog entry, and `LiveTranslateCopyTests` fails if a notice exists
/// without a sentence in both languages.
struct WardenNoticeSurface: Equatable {

    /// Which of the two moments this is. The reason the surface carries the
    /// notice rather than only its words: a test can assert *which* moment a
    /// session is showing without parsing a sentence, and a later surface
    /// that wants to treat the two differently has the case to switch on.
    let notice: LocalBrainWardenNotice
    let locale: Locale

    init(notice: LocalBrainWardenNotice, locale: Locale) {
        self.notice = notice
        self.locale = locale
    }

    /// The sentence the elder reads — "Hold on a sec — getting the translation
    /// ready." while a load is announced, "Switched for your voice request."
    /// when the model is handed to a voice turn — in the active language.
    var copy: String {
        L10n.str(notice.copyKey, locale: locale)
    }
}

/// The warden's notice, drawn as a brief status over the picture.
///
/// **A status, not a modal.** There is nothing to tap, nothing to dismiss and
/// nothing to answer: both moments it describes end on their own, so the
/// banner's whole life is the model's (`wardenNoticeDismissSeconds`), and it
/// exists on screen exactly while `wardenNotice` does. The view holds no
/// state about it and starts no task for it, which is what keeps the render
/// path a pure function of the surface it was handed.
///
/// It is drawn in the session's chrome rather than in the overlay because it
/// is a fact about the *session* — work the tier is doing — and not about a
/// region, and it sits directly under the top strip because that is the band
/// the elder is already looking at when the screen changes under them. Full
/// width and on the app's card token, so it stays readable over whatever the
/// camera happens to be pointing at; at the body floor, so it is legible at
/// arm's length.
struct LiveTranslateWardenNoticeBanner: View {

    let surface: WardenNoticeSurface

    var body: some View {
        Text(surface.copy)
            .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize, weight: .semibold))
            .foregroundColor(DesignTokens.textPrimary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, DesignTokens.interElementSpacing * 2)
            .padding(.vertical, DesignTokens.interElementSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
            .accessibilityIdentifier("livetranslate.warden.notice")
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
    /// The height the card's **content** wants at the width it was given, for
    /// a caller that has to decide how much room to leave it (Workstream B).
    ///
    /// A defaulted `var` rather than a `let`, deliberately: every construction
    /// site that predates the focused read keeps the memberwise initializer it
    /// was written against — the frozen path passes nothing and measures
    /// nothing — and a `let` with a default is excluded from that initializer,
    /// which would break them all instead.
    ///
    /// The focused read is the caller that needs it: its panel is bounded by
    /// the picture above it, so it must know what the rows actually need before
    /// it decides how far the picture may grow. Only the card can answer that —
    /// it is the thing that laid the rows out at the width in force — and the
    /// alternative, an estimate from the row count, is a number that would drift
    /// from the type floors it is supposed to respect.
    var onContentHeight: ((CGFloat) -> Void)?

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
            // The content's natural height, measured off its own frame: inside
            // the scroll view that frame is the height the rows want at the
            // offered width, which is the number the caller asked for. A
            // background reader, so the measurement never changes the layout it
            // measures.
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { onContentHeight?(proxy.size.height) }
                        .onChange(of: proxy.size.height) { height in
                            onContentHeight?(height)
                        }
                })
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
                // [SNAPSHOT-ORDER] (owner directive, 2026-09-20: "show the
                // original language and then the translated text.") The
                // original reads FIRST, the translation beneath it — the
                // translation keeps the prominent weight so the eye still
                // lands where the answer is.
                if let source = row.source, !source.isEmpty {
                    Text(source)
                        .font(DesignTokens.warmFont(size: DesignTokens.minCaptionPointSize))
                        .foregroundColor(DesignTokens.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
/// out, and it is also the only place the elder's three gestures can be read off
/// the picture.
///
/// **Why the gestures are UIKit's here.** A pinch belongs to the picture, a
/// drag moves the window, and a tap means "look *there*" — and "there" is a
/// point in the *frame's* coordinates, in all three cases through the same map
/// the picture is drawn with (`LiveCameraPresentation`). The layer's own
/// `captureDevicePointConverted(fromLayerPoint:)` still does the last step of
/// the tap, because it is the conversion that knows the aspect fit and the
/// device's zoom; what the presentation adds is the window the elder has moved
/// to, which the layer knows nothing about. Attaching the recognisers to this
/// view (rather than a SwiftUI gesture on the whole container) is also what
/// keeps them off the chrome: a tap that lands on the overlay's boxes, on a
/// button or on the results card is handled above this view and never reaches
/// it.
///
/// **Gesture ownership (owner follow-up, 2026-09-18).** One finger drags — never
/// two, or a pinch would pan the picture while it zooms it — and the drag only
/// exists once there is a window to move: while the whole frame is visible the
/// recogniser is switched off, so a finger on the picture does nothing rather
/// than moving a window that is already the frame. Taps are unaffected either
/// way (a still finger is not a drag), so a bubble above this view still takes
/// the tap it always took and a tap on the picture still focuses.
///
/// **The stabilization is not a gesture.** Every conversion here goes through
/// the presentation, which carries the frame's stabilization composed into the
/// elder's window (owner device verdict, 2026-09-18) — so where the finger is on
/// the *picture* is answered through the picture as drawn, while the drag's
/// existence is still the elder's own window (`isWindowed`). The correction
/// moves the picture; it never moves the window the elder is holding.
struct LiveTranslatePreviewHost: UIViewRepresentable {

    let layer: AVCaptureVideoPreviewLayer
    /// The window the picture is drawn and read through, at the frame size the
    /// camera is delivering — with the frame's stabilization already composed
    /// into it (see `LiveTranslateView.displayedCrop()`).
    let presentation: LiveCameraPresentation
    /// Whether the elder's own window is narrower than the frame, which is the
    /// one thing that decides whether a drag has anything to move.
    ///
    /// Stated separately from `presentation.crop.isWhole` because the two
    /// answer different questions now that the picture is stabilized: the
    /// presentation's crop is the *drawing's* window and is never whole while a
    /// margin is held, whereas the drag is the elder's gesture on the *zoom
    /// model's* window — and at the at-rest zoom there is still nothing to pan
    /// (a drag would be clamped to zero by the model's own pan limit, so the
    /// recogniser is switched off rather than left to do nothing).
    let isWindowed: Bool
    /// A pinch in flight: the recogniser's cumulative scale, 1 at the moment
    /// the fingers landed, and where they landed — a point **inside the visible
    /// window** (0–1 of the crop), which is the anchoring the zoom holds.
    let onPinch: (CGFloat, CGPoint) -> Void
    /// The pinch's end (lifted, cancelled or failed).
    let onPinchEnded: () -> Void
    /// A drag in flight, as the window offset it asks for in frame fractions
    /// (cumulative from the moment the finger landed, the recogniser's own
    /// convention), converted here through the presentation.
    let onPan: (CGPoint) -> Void
    /// The drag's end.
    let onPanEnded: () -> Void
    /// A tap on the picture, converted to the device's own point of interest
    /// (normalized, top-left origin) through the window and then the layer.
    let onFocusTap: (CGPoint) -> Void
    /// [POINT-ASK] The same tap, in the **frame's** coordinates (pixels,
    /// top-left origin) — the picture's own space, which the point-ask
    /// session resolves the tapped box in. The focus path and this path
    /// are one gesture with two intents; neither replaces the other.
    let onPointAskTap: (CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.layer.addSublayer(layer)
        view.previewLayer = layer
        view.isMultipleTouchEnabled = true
        view.addGestureRecognizer(context.coordinator.makePinchRecognizer())
        let pan = context.coordinator.makePanRecognizer()
        view.addGestureRecognizer(pan)
        context.coordinator.panRecognizer = pan
        view.addGestureRecognizer(context.coordinator.makeTapRecognizer())
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        // The closures are the body's (they capture the surface this render was
        // built from), so each pass refreshes them; the recognisers themselves
        // are made once, in `makeUIView`.
        context.coordinator.onPinch = onPinch
        context.coordinator.onPinchEnded = onPinchEnded
        context.coordinator.onPan = onPan
        context.coordinator.onPanEnded = onPanEnded
        context.coordinator.onFocusTap = onFocusTap
        context.coordinator.onPointAskTap = onPointAskTap
        context.coordinator.presentation = presentation
        // The drag exists only while a window does: with the whole frame on
        // screen there is nothing to move, and a disabled recogniser leaves the
        // finger to the tap that was already there (see `isWindowed`).
        context.coordinator.panRecognizer?.isEnabled = isWindowed
        view.presentation = presentation
        view.layoutPreviewLayer()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(presentation: presentation,
                    onPinch: onPinch,
                    onPinchEnded: onPinchEnded,
                    onPan: onPan,
                    onPanEnded: onPanEnded,
                    onFocusTap: onFocusTap,
                    onPointAskTap: onPointAskTap)
    }

    /// The gesture target: it reads each touch in the preview view's own
    /// coordinates and converts it through the presentation (and, for the tap,
    /// on the layer), so nothing here holds session state — the closures it
    /// calls are the surface's.
    final class Coordinator: NSObject {

        var presentation: LiveCameraPresentation
        var onPinch: (CGFloat, CGPoint) -> Void
        var onPinchEnded: () -> Void
        var onPan: (CGPoint) -> Void
        var onPanEnded: () -> Void
        var onFocusTap: (CGPoint) -> Void
        var onPointAskTap: (CGPoint) -> Void
        weak var panRecognizer: UIPanGestureRecognizer?

        init(presentation: LiveCameraPresentation,
             onPinch: @escaping (CGFloat, CGPoint) -> Void,
             onPinchEnded: @escaping () -> Void,
             onPan: @escaping (CGPoint) -> Void,
             onPanEnded: @escaping () -> Void,
             onFocusTap: @escaping (CGPoint) -> Void,
             onPointAskTap: @escaping (CGPoint) -> Void = { _ in }) {
            self.presentation = presentation
            self.onPinch = onPinch
            self.onPinchEnded = onPinchEnded
            self.onPan = onPan
            self.onPanEnded = onPanEnded
            self.onFocusTap = onFocusTap
            self.onPointAskTap = onPointAskTap
        }

        func makePinchRecognizer() -> UIPinchGestureRecognizer {
            let recognizer = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
            return recognizer
        }

        /// One finger, because two are the pinch's: a drag that ran during a
        /// pinch would move the window while the zoom was moving it too, and
        /// neither gesture would be doing what the elder's hand meant.
        func makePanRecognizer() -> UIPanGestureRecognizer {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
            recognizer.minimumNumberOfTouches = 1
            recognizer.maximumNumberOfTouches = 1
            return recognizer
        }

        func makeTapRecognizer() -> UITapGestureRecognizer {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            // One finger, one tap: a two-finger touch belongs to the pinch, and
            // focusing in the middle of a zoom would fight it. Nothing else is
            // configured — a single-tap recogniser, a pinch and a one-finger
            // pan do not contend, because a still finger is not a drag and a
            // moving one is not a tap.
            recognizer.numberOfTouchesRequired = 1
            recognizer.numberOfTapsRequired = 1
            return recognizer
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                onPinch(recognizer.scale, focusPoint(of: recognizer))
            case .ended, .cancelled, .failed:
                onPinchEnded()
            default:
                break
            }
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began, .changed:
                // The recogniser's translation is cumulative from the touch
                // down, and the surface measures it from the window the drag
                // started at, so a drag that runs past the frame's edge and
                // comes back resumes where the finger is.
                onPan(presentation.panOffset(ofContainerTranslation: recognizer.translation(in: view)))
            case .ended, .cancelled, .failed:
                onPanEnded()
            default:
                break
            }
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view as? PreviewView,
                  let layer = view.previewLayer else { return }
            let point = recognizer.location(in: view)
            // Two steps, in this order and for this reason: the presentation
            // says which *frame* point the elder is pointing at (the window
            // has moved, and the screen position of a frame point moved with
            // it), and the layer says where in the device's own coordinates
            // that frame point is.
            let framePoint = presentation.framePoint(ofContainerPoint: point)
            let unzoomedPoint = presentation.unzoomedContainerPoint(ofFramePoint: framePoint)
            onFocusTap(layer.captureDevicePointConverted(fromLayerPoint: unzoomedPoint))
            // [POINT-ASK] The same tap, in the picture's own coordinates:
            // the session anchors the box where the finger is on the frame
            // (which is the same place the focus landed — one map, two
            // intents).
            onPointAskTap(framePoint)
        }

        /// Where the fingers landed, inside the visible window: 0–1 from the
        /// window's own top-left corner, which is the coordinate the zoom's
        /// anchoring is expressed in (the window *is* the picture on screen, so
        /// this is also the elder's position on the glass).
        private func focusPoint(of recognizer: UIPinchGestureRecognizer) -> CGPoint {
            guard let view = recognizer.view else { return LiveCameraCrop.whole.center }
            let framePoint = presentation.framePoint(ofContainerPoint: recognizer.location(in: view))
            return presentation.crop.cropPoint(ofFramePoint: framePoint)
        }
    }

    /// The container whose own layout pass drives the layer's frame — a
    /// `UIView` whose sublayer is sized in `layoutSubviews`, so the preview
    /// follows a rotation without the SwiftUI side scheduling anything.
    final class PreviewView: UIView {
        var previewLayer: AVCaptureVideoPreviewLayer?
        /// The window the drawing is moved and scaled into, refreshed on every
        /// SwiftUI pass.
        var presentation = LiveCameraPresentation(crop: .whole, pictureRect: .zero)

        override func layoutSubviews() {
            super.layoutSubviews()
            layoutPreviewLayer()
        }

        func layoutPreviewLayer() {
            guard let previewLayer, window != nil || superview != nil else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // `bounds` and `position`, not `frame`: `frame` is derived from the
            // transform, so assigning it while one is set would resize the
            // layer's own drawing area to compensate, and the window would be
            // drawn through a layer shrunk around it. The anchor point is the
            // default (0.5, 0.5) — the transform is corrected about the same
            // point the layer actually rotates around.
            previewLayer.bounds = CGRect(origin: .zero, size: bounds.size)
            previewLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            previewLayer.setAffineTransform(
                presentation.layerTransform(anchor: CGPoint(x: bounds.midX, y: bounds.midY)))
            CATransaction.commit()
        }
    }
}

// MARK: - Point, tap & ask surfaces

/// [POINT-ASK] The consent sheet the point-ask session presents at its
/// first cloud need — the same card, the same equal-weight choices and the
/// same no-auto-dismiss rule as the shipped `ConsentPromptView`, with the
/// point-ask disclosure copy (design §5: what leaves — the small crop,
/// nothing else — where it goes, nothing until agreement, stop any time).
struct PointAskConsentPromptView: View {

    let surface: PointAskConsentSurface
    let onGrant: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(surface.title)
                .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize, weight: .semibold))
                .foregroundColor(DesignTokens.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("pointask.consent.heading")

            Text(surface.message)
                .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.textPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("pointask.consent.message")

            if let failure = surface.failureMessage {
                Text(failure)
                    .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize))
                    .foregroundColor(DesignTokens.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pointask.consent.failure")
            }

            VStack(spacing: 12) {
                ForEach(surface.actions, id: \.kind) { action in
                    actionButton(action)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    /// The one button construction: both choices come through it, so
    /// neither can acquire a style the other does not have (the shipped
    /// `ConsentPromptView` rule).
    private func actionButton(_ action: PointAskConsentSurface.Action) -> some View {
        Button {
            switch action.kind {
            case .grant: onGrant()
            case .decline: onDecline()
            }
        } label: {
            Text(action.title)
                .font(DesignTokens.warmFont(size: DesignTokens.minBodyPointSize, weight: .semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: DesignTokens.minTapTargetSize)
                .background(DesignTokens.accent)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(action.accessibilityIdentifier)
    }
}

/// [POINT-ASK] The visible cloud indicator (design §5): on while a crop
/// may be leaving the phone, labelled from the catalog in the active
/// language ("Looking online" — the mirror of the shipped "Translating
/// online" indicator).
struct PointAskCloudIndicatorView: View {

    let locale: Locale

    /// An SF Symbol name is a system identifier, not user-visible copy, so
    /// it is a constant here — the same rule every other glyph in this
    /// file states.
    static let symbolName = "icloud.and.arrow.up"

    var body: some View {
        HStack(spacing: DesignTokens.interElementSpacing / 2) {
            Image(systemName: Self.symbolName)
                .font(DesignTokens.warmFont(size: DesignTokens.minCaptionPointSize,
                                            weight: .semibold))
            Text(L10n.str("pointask.cloudIndicator.label", locale: locale))
                .font(DesignTokens.warmFont(size: DesignTokens.minCaptionPointSize,
                                            weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(DesignTokens.textPrimary)
        .padding(.horizontal, DesignTokens.interElementSpacing)
        .frame(minHeight: DesignTokens.minTapTargetSize)
        .background(DesignTokens.card)
        .clipShape(Capsule())
        .accessibilityIdentifier("pointask.cloudIndicator")
    }
}
