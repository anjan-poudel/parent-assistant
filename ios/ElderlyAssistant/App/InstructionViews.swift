import AVKit
import SwiftUI
import UIKit

// MARK: - Shared copy keys

/// C08 — the only copy keys these three surfaces render (design L2 §10.5's
/// shipping `instruction.*` family plus the reused shipping keys).
///
/// Values, not inline literals: the card, cover and editor all resolve
/// through `L10n.str`/`L10n.fmt`, and the surface suite can pin each key's
/// presence in both shipped languages from one place. No elder-facing
/// English sentence lives in this file.
enum InstructionSurfaceKeys {
    // Card (§4.10 table, §10.3)
    static let imageAccessibility = "instruction.image.accessibility"
    static let imageUnavailable = "instruction.image.unavailable"
    static let videoAccessibility = "instruction.video.accessibility"
    static let videoPlay = "instruction.video.play"
    static let videoUnavailable = "instruction.video.unavailable"
    static let unsupported = "instruction.unsupported"
    static let removed = "instruction.removed"

    // Cover (§10.3)
    static let videoPreparing = "instruction.video.preparing"
    static let close = "common.close"

    // Editor (§10.1, §10.3, §10.5)
    static let title = "instruction.title"
    static let cancel = "common.cancel"
    static let done = "instruction.done"
    static let remove = "instruction.remove"
    static let textPlaceholder = "instruction.textPlaceholder"
    static let kindText = "instruction.kind.text"
    static let kindImage = "instruction.kind.image"
    static let kindVideo = "instruction.kind.video"
    static let imageAdd = "visualAid.add"
    static let imageChange = "instruction.image.change"
    static let captionPlaceholder = "visualAid.captionPlaceholder"
    static let videoAdd = "instruction.video.add"
    static let videoRecord = "instruction.video.record"
    static let videoChange = "instruction.video.change"
    static let videoRecordingLimit = "instruction.video.recordingLimit"
    static let videoValidating = "instruction.video.validating"
    static let foregroundNote = "instruction.foregroundNote"
}

// MARK: - Card (design §2.8, §4.10)

/// C08 — the read-only instruction card (design L2 §2.8.1–2, §4.10,
/// §10.1–§10.3; FR-RIE-007/009/010, FR-RIE-024, NFR-RIE-001/002/010).
///
/// One collapsed state in, one honest surface out:
///
///  - `.none` renders `EmptyView` — nothing at all, not an empty container
///    with padding (P-9, NFR-RIE-010). The fired screen that carries a
///    photo-only reminder is therefore exactly today's screen.
///  - `.text` is the instruction's words full width, never truncated.
///  - `.image` renders the photo and its optional caption as its own text.
///    The card loads the bytes itself in `.task(id:)`, never in `body`; a
///    failed load (or no loader injected) shows the one plain
///    `instruction.image.unavailable` line.
///  - `.video` renders a ≥44 pt Play button plus the caption. The card
///    creates no player, no controller and no URL: the button calls the
///    injected reachability action, and the host presents the playback
///    cover after the tap (FR-RIE-018). With no playback action the card
///    shows the plain unavailable line instead of a dead control.
///  - `.unsupported` shows any saved text plus the one plain note and
///    never a play, open or link control (FR-RIE-024).
///  - `.removed` shows the one plain removed line and no control.
///
/// The card reaches no store, scheduler, event service or coordinator: the
/// image seam and the play action are the whole dependency set. Every
/// visible string is a catalogue key resolved through `L10n` against the
/// app's own locale environment; nothing renders a filename, path, URL or
/// error code.
struct InstructionCardView: View {

    @Environment(\.appAppearance) private var appearance
    @Environment(\.locale) private var locale

    /// The collapsed state `InstructionPresentation` handed the host.
    let state: InstructionDisplayState
    /// The D6 fire-time line, already formatted by the host. Nil means no
    /// time line; it is only rendered for a non-`.none` state.
    let timeText: String?
    /// The card's image seam. Nil means this host cannot decode the photo,
    /// so the honest surface is the plain unavailable line.
    let imageLoader: (any InstructionImageLoading)?
    /// The host's playback action for `.video` (the bare filename). Nil
    /// means playback is not available, so the card offers no control.
    let onPlay: ((String) -> Void)?

    @State private var loadedImage: UIImage?
    @State private var imageUnavailable = false

    /// The Play control's tap floor (design §10.1: 44×44 pt). Named so the
    /// surface suite can pin the floor without rendering.
    static let playTapTarget: CGFloat = DesignTokens.minTapTargetSize

    init(state: InstructionDisplayState,
         timeText: String? = nil,
         imageLoader: (any InstructionImageLoading)? = nil,
         onPlay: ((String) -> Void)? = nil) {
        self.state = state
        self.timeText = timeText
        self.imageLoader = imageLoader
        self.onPlay = onPlay
    }

    /// What a state renders, independent of drawing. This is the value half
    /// of the §4.10 table and the one place "video without playback is not
    /// a play control" is decided.
    enum Surface: Equatable {
        case nothing
        case text(String)
        case image(caption: String?)
        case video(caption: String?, hasPlay: Bool)
        case unsupported(String?)
        case removed
    }

    /// The total mapping the card draws (design §4.10; §11.3 Q).
    static func surface(for state: InstructionDisplayState,
                        hasPlayback: Bool) -> Surface {
        switch state {
        case .none:
            return .nothing
        case .text(let text):
            return .text(text)
        case .image(_, let caption):
            return .image(caption: caption)
        case .video(_, let caption):
            return .video(caption: caption, hasPlay: hasPlayback)
        case .unsupported(let text):
            return .unsupported(text)
        case .removed:
            return .removed
        }
    }

    /// The image seam's total mapping: success carries the decoded photo,
    /// every typed failure is the one plain line (no diagnostic escapes).
    enum ImageOutcome {
        case image(UIImage)
        case unavailable
    }

    static func imageOutcome(_ result: Result<UIImage, InstructionImageFailure>) -> ImageOutcome {
        switch result {
        case .success(let image):
            return .image(image)
        case .failure:
            return .unavailable
        }
    }

    var body: some View {
        // `.none` is nothing at all — deliberately not a padded container
        // (P-9). The guard exists before any layout modifier so an empty
        // state can add no space to the host's screen.
        if case .none = state {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let timeText {
                    Text(timeText)
                        .font(.system(size: appearance.typography.captionPointSize,
                                      weight: .semibold))
                        .foregroundStyle(appearance.colors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                surfaceContent
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .appSurface(role: .card)
        }
    }

    /// One arm per display state, each rendering only what the state can
    /// support (design §4.10).
    @ViewBuilder
    private var surfaceContent: some View {
        switch state {
        case .none:
            // Unreachable from `body` (the guard above); kept so the switch
            // is total and a future caller cannot invent a container.
            EmptyView()

        case .text(let text):
            Text(text)
                .font(.system(size: appearance.typography.bodyPointSize))
                .foregroundStyle(appearance.colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

        case .image(let filename, let caption):
            imageContent(filename: filename, caption: caption)

        case .video(let filename, let caption):
            if let onPlay {
                Button {
                    onPlay(filename)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text(L10n.str(InstructionSurfaceKeys.videoPlay, locale: locale))
                    }
                    .font(.system(size: appearance.typography.bodyPointSize,
                                  weight: .bold))
                    .foregroundStyle(appearance.colors.accentForeground)
                    .padding(.horizontal, 20)
                    .frame(minWidth: InstructionCardView.playTapTarget,
                           minHeight: InstructionCardView.playTapTarget)
                    .background(appearance.colors.accent)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.str(
                    InstructionSurfaceKeys.videoAccessibility, locale: locale)))
            } else {
                // No playback path: no dead button. The one plain line is
                // the same line a failed playback shows in the cover.
                Text(L10n.str(InstructionSurfaceKeys.videoUnavailable, locale: locale))
                    .font(.system(size: appearance.typography.bodyPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let caption {
                captionText(caption)
            }

        case .unsupported(let text):
            // Forward tolerance: the saved words survive, the note is the
            // only extra, and no play/open/link control is produced
            // (FR-RIE-024, §11.3 Q).
            if let text {
                Text(text)
                    .font(.system(size: appearance.typography.bodyPointSize))
                    .foregroundStyle(appearance.colors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.str(InstructionSurfaceKeys.unsupported, locale: locale))
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

        case .removed:
            Text(L10n.str(InstructionSurfaceKeys.removed, locale: locale))
                .font(.system(size: appearance.typography.bodyPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The photo plus its optional caption, or the one plain unavailable
    /// line when this host cannot decode it (or the file has gone).
    @ViewBuilder
    private func imageContent(filename: String, caption: String?) -> some View {
        if let imageLoader {
            Group {
                if let loadedImage {
                    Image(uiImage: loadedImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(Text(L10n.str(
                            InstructionSurfaceKeys.imageAccessibility, locale: locale)))
                } else if imageUnavailable {
                    Text(L10n.str(InstructionSurfaceKeys.imageUnavailable, locale: locale))
                        .font(.system(size: appearance.typography.bodyPointSize))
                        .foregroundStyle(appearance.colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Loading happens outside `body`, keyed on the bare filename
            // (design §2.8.2): a caption edit never re-reads the file.
            .task(id: filename) {
                await loadImage(filename: filename, using: imageLoader)
            }
        } else {
            Text(L10n.str(InstructionSurfaceKeys.imageUnavailable, locale: locale))
                .font(.system(size: appearance.typography.bodyPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let caption {
            captionText(caption)
        }
    }

    /// The caption is its own text, never merged into the image's
    /// accessibility label (design §4.10, §10.3).
    private func captionText(_ caption: String) -> some View {
        Text(caption)
            .font(.system(size: appearance.typography.captionPointSize))
            .foregroundStyle(appearance.colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The single load path. State is reset first so a replaced photo never
    /// shows the previous image while the new one resolves.
    @MainActor
    private func loadImage(filename: String, using imageLoader: any InstructionImageLoading) async {
        loadedImage = nil
        imageUnavailable = false
        switch InstructionCardView.imageOutcome(imageLoader.loadImage(filename: filename)) {
        case .image(let image):
            loadedImage = image
        case .unavailable:
            imageUnavailable = true
        }
    }
}

// MARK: - Playback cover (design §2.8.3)

/// C08 — the full-screen playback cover (design L2 §2.8.3, §10.2–§10.4,
/// §11.3 I/O; FR-RIE-018/020).
///
/// The cover exists only because the person activated the card's Play
/// button (or because a host explicitly decided to present playback). It
/// owns no autoplay path of its own:
///
///  - `startsWhenPresented` is the host's explicit statement that the tap
///    already happened; only then does the cover call the controller's
///    `start()`, exactly once. A host that wants to drive playback itself
///    passes `false` and calls `start()` itself.
///  - The player is the controller's `player` — no `AVPlayer` is
///    constructed here, and nothing retries a failed session.
///  - Every typed playback failure becomes the one plain
///    `instruction.video.unavailable` line (`InstructionMessageKey`), and
///    Close is always composed outside the state switch.
///  - Dismissal (the Close button or the cover being torn down) calls
///    `close()`, which pauses before releasing through the adapter.
///
/// There is no share sheet, no background audio, no URL/link path and no
/// title claim: the VoiceOver order is the player (system) then Close, as
/// design §10.3 requires.
struct InstructionCoverView: View {

    @Environment(\.appAppearance) private var appearance
    @Environment(\.locale) private var locale

    @ObservedObject private var controller: InstructionPlaybackController
    /// True when the host already resolved the activation (the person
    /// tapped Play). False lets the host drive `start()` itself.
    private let startsWhenPresented: Bool
    private let onClose: () -> Void

    init(controller: InstructionPlaybackController,
         startsWhenPresented: Bool = true,
         onClose: @escaping () -> Void) {
        _controller = ObservedObject(wrappedValue: controller)
        self.startsWhenPresented = startsWhenPresented
        self.onClose = onClose
    }

    /// The one plain line a state needs, if any (design §10.3). Readiness
    /// and the finished frame render the player; idle/closed render
    /// nothing; a failure renders the typed failure's single sentence.
    static func messageKey(for state: InstructionPlaybackController.State) -> String? {
        switch state {
        case .preflighting, .preparing:
            return InstructionSurfaceKeys.videoPreparing
        case .failed(let failure):
            return InstructionMessageKey.forPlayback(failure)
        case .idle, .ready, .finished, .closed:
            return nil
        }
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            VStack(spacing: 16) {
                coverContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                closeBar
            }
            .padding(20)
        }
        .onAppear {
            if startsWhenPresented {
                controller.start()
            }
            // A host that started playback itself may present an already
            // ready controller; this is the same activation, not a second
            // one, and start() above is a no-op in that phase.
            playWhenReady()
        }
        .onChange(of: controller.state) { state in
            // The tap already happened (this cover is its consequence): the
            // system player starts as the ready phase of that same action,
            // never before it. This is the only play call in the file.
            if case .ready = state {
                playWhenReady()
            }
        }
        .onDisappear {
            // The one close path, idempotent: a swipe dismissal and the
            // Close button both pause-then-release through the adapter.
            controller.close()
        }
    }

    /// The phase content. The player is the controller's own object; the
    /// cover constructs no player and starts no second session.
    @ViewBuilder
    private var coverContent: some View {
        switch controller.state {
        case .idle, .closed:
            EmptyView()

        case .preflighting, .preparing:
            HStack(spacing: 10) {
                ProgressView()
                    .tint(.white)
                    .accessibilityHidden(true)
                Text(L10n.str(InstructionSurfaceKeys.videoPreparing, locale: locale))
                    .font(.system(size: appearance.typography.bodyPointSize))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

        case .ready, .finished:
            if let player = controller.player {
                VideoPlayer(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        case .failed(let failure):
            // One plain line: no error code, filename, path or technical
            // detail (FR-RIE-020). Close stays available below.
            Text(L10n.str(InstructionMessageKey.forPlayback(failure), locale: locale))
                .font(.system(size: appearance.typography.bodyPointSize))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Close is composed outside every phase branch, so it is available in
    /// failure, preparing and finished alike (design §10.1–§10.3).
    private var closeBar: some View {
        Button {
            controller.close()
            onClose()
        } label: {
            Text(L10n.str(InstructionSurfaceKeys.close, locale: locale))
                .font(.system(size: appearance.typography.bodyPointSize, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                // A floor, not a fixed height: the label wraps at large
                // Dynamic Type sizes instead of shrinking or clipping.
                .frame(minHeight: DesignTokens.minTapTargetSize + 12)
                .background(Color.white.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius,
                                            style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L10n.str(InstructionSurfaceKeys.close, locale: locale)))
    }

    /// Starts the system player for a session that is already ready. No
    /// other call site plays audio.
    private func playWhenReady() {
        guard case .ready = controller.state else { return }
        controller.player?.play()
    }
}

// MARK: - Editor (design §2.8.4–6, §4.2)

/// C08 — the shared text/photo/video editor (design L2 §2.8.4–6, §4.2,
/// §10.1–§10.3; FR-RIE-002/003/007/009/024, NFR-RIE-001/002).
///
/// The editor mutates the injected draft and reports one resolved commit;
/// it never saves, writes, schedules or reaches a store. Its whole service
/// surface is the injected capture coordinator:
///
///  - text entry goes through `InstructionDraft.setText`;
///  - the photo button opens the host's existing photo flow through the
///    injected `pickImage` closure (the shipping out-of-process picker;
///    this file imports no PhotosUI and requests no photo permission);
///  - video record/pick go through `InstructionVideoCaptureCoordinator`,
///    and an accepted video is consumed exactly once into the draft;
///  - Save is enabled only when `draft.resolvedCommit != nil`, so a media
///    draft with neither a stored filename nor pending bytes cannot save;
///  - Remove is its own explicit control (never "empty text means delete"),
///    offered only for an instruction that currently exists.
///
/// The video section states the foreground-only limitation
/// (`instruction.foregroundNote`) where the family chooses a video, and
/// every permission/import problem maps through `InstructionMessageKey`
/// to one plain line. No player, URL field, link playback, share sheet,
/// transcode, trimming, Settings deep link or new permission request
/// exists here.
struct InstructionEditorView: View {

    @Environment(\.appAppearance) private var appearance
    @Environment(\.locale) private var locale

    @Binding private var draft: InstructionDraft
    @ObservedObject private var capture: InstructionVideoCaptureCoordinator
    /// A save failure's catalogue key (the host maps the write error
    /// through `InstructionMessageKey.forWrite`). Nil shows no line.
    private let saveFailureKey: String?
    /// Opens the host's existing photo flow and calls back with the picked
    /// image (nil when the person dismissed it). The editor never presents
    /// a picker itself.
    private let pickImage: (@escaping (UIImage?) -> Void) -> Void
    private let onSave: (InstructionCommit) -> Void
    private let onCancel: () -> Void

    init(draft: Binding<InstructionDraft>,
         capture: InstructionVideoCaptureCoordinator,
         saveFailureKey: String? = nil,
         pickImage: @escaping (@escaping (UIImage?) -> Void) -> Void,
         onSave: @escaping (InstructionCommit) -> Void,
         onCancel: @escaping () -> Void) {
        _draft = draft
        _capture = ObservedObject(wrappedValue: capture)
        self.saveFailureKey = saveFailureKey
        self.pickImage = pickImage
        self.onSave = onSave
        self.onCancel = onCancel
    }

    // MARK: - Pure seams (the surface suite pins these)

    /// The Save gate: one resolved commit, or nothing (T-018 acceptance).
    static func canSave(_ draft: InstructionDraft) -> Bool {
        draft.resolvedCommit != nil
    }

    /// The kind picker's own text (design §10.5 rows 5–7).
    static func kindKey(for kind: InstructionKind) -> String {
        switch kind {
        case .text:
            return InstructionSurfaceKeys.kindText
        case .image:
            return InstructionSurfaceKeys.kindImage
        case .video:
            return InstructionSurfaceKeys.kindVideo
        }
    }

    /// The photo control's label: "Change photo" once one is selected,
    /// the shipping "Add photo" otherwise.
    static func imageButtonKey(hasImage: Bool) -> String {
        hasImage ? InstructionSurfaceKeys.imageChange : InstructionSurfaceKeys.imageAdd
    }

    /// The video control's label: "Change video" once one is selected,
    /// "Choose a video" otherwise.
    static func videoButtonKey(hasVideo: Bool) -> String {
        hasVideo ? InstructionSurfaceKeys.videoChange : InstructionSurfaceKeys.videoAdd
    }

    /// Remove is a real choice only when the instruction exists.
    static func removeIsOffered(for draft: InstructionDraft) -> Bool {
        draft.original?.isPresent == true
    }

    /// The capture machine's one plain line (design §3.3, §6.7, §10.3).
    /// Busy system surfaces (`picking`/`recording`) and an accepted video
    /// say nothing extra; the asynchronous validating phase is labelled
    /// (no spinner without a label); a permission stop and an import
    /// failure map through `InstructionMessageKey` (cancellation is nil).
    static func feedbackKey(for state: InstructionVideoCaptureCoordinator.State) -> String? {
        switch state {
        case .idle, .picking, .recording, .ready:
            return nil
        case .validating:
            return InstructionSurfaceKeys.videoValidating
        case .failed(.permission(let problem)):
            return InstructionMessageKey.forPermission(problem)
        case .failed(.importError(let error)):
            return InstructionMessageKey.forImport(error)
        }
    }

    /// Applies a picked image (or a cancelled pick, which changes nothing)
    /// to the draft. The payload carries no filename: the store mints one
    /// at commit, so a replacement can never keep a stale name.
    static func applyingPickedImage(_ image: UIImage?,
                                    caption: String?,
                                    to draft: InstructionDraft) -> InstructionDraft {
        guard let image else { return draft }
        var updated = draft
        updated.setPendingImage(image, caption: caption)
        return updated
    }

    /// Applies an accepted, already-consumed video to the draft, keeping a
    /// caption that belonged to a video draft. The draft becomes a video
    /// write: the person asked for this video, and the kind picker shows it.
    static func applyingAcceptedVideo(_ video: AcceptedInstructionVideo,
                                      to draft: InstructionDraft) -> InstructionDraft {
        var updated = draft
        let keepsCaption = updated.payload?.kind == .video
        updated.setPendingVideo(video, caption: keepsCaption ? updated.payload?.caption : nil)
        return updated
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    kindPicker
                    kindSection
                    feedbackLines
                    removeButton
                }
                .padding(20)
            }
        }
        .background(appearance.colors.background)
        .onAppear {
            // A coordinator that reached `.ready` before this editor
            // appeared still hands its bytes over once (exactly-once is
            // the coordinator's contract).
            consumeAcceptedVideoIfReady()
        }
        .onChange(of: capture.state) { _ in
            consumeAcceptedVideoIfReady()
        }
        .onDisappear {
            // Dismissing the editor never leaves a system surface or a
            // staged draft behind. Idempotent.
            capture.cancel()
        }
    }

    private var isEditable: Bool {
        draft.loadState == .loaded
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: cancelEditing) {
                Text(L10n.str(InstructionSurfaceKeys.cancel, locale: locale))
                    .font(.system(size: appearance.typography.bodyPointSize,
                                  weight: .semibold))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .frame(minWidth: DesignTokens.minTapTargetSize,
                           minHeight: DesignTokens.minTapTargetSize)
            }
            .buttonStyle(.plain)

            Spacer()

            Text(L10n.str(InstructionSurfaceKeys.title, locale: locale))
                .font(.system(size: appearance.typography.bodyPointSize,
                              weight: .bold))
                .foregroundStyle(appearance.colors.textPrimary)

            Spacer()

            Button(action: save) {
                Text(L10n.str(InstructionSurfaceKeys.done, locale: locale))
                    .font(.system(size: appearance.typography.bodyPointSize,
                                  weight: .bold))
                    .foregroundStyle(canSave ? appearance.colors.accent
                                             : appearance.colors.textSecondary)
                    .frame(minWidth: DesignTokens.minTapTargetSize,
                           minHeight: DesignTokens.minTapTargetSize)
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var canSave: Bool {
        InstructionEditorView.canSave(draft)
    }

    /// Three real buttons, each at the 44 pt floor. Selection is carried by
    /// a checkmark and the `.isSelected` trait as well as colour, so no
    /// meaning is colour-only (design §10.1, §10.4).
    private var kindPicker: some View {
        HStack(spacing: 8) {
            ForEach(InstructionKind.allCases, id: \.rawValue) { kind in
                kindButton(kind)
            }
        }
    }

    private func kindButton(_ kind: InstructionKind) -> some View {
        let selected = draft.payload?.kind == kind
        return Button {
            draft.chooseKind(kind)
        } label: {
            HStack(spacing: 6) {
                if selected {
                    Image(systemName: "checkmark")
                        .accessibilityHidden(true)
                }
                Text(L10n.str(InstructionEditorView.kindKey(for: kind), locale: locale))
            }
            .font(.system(size: appearance.typography.bodyPointSize,
                          weight: .semibold))
            .foregroundStyle(selected ? appearance.colors.accentForeground
                                      : appearance.colors.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            .background(selected ? appearance.colors.accent
                                 : appearance.colors.card)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEditable)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// The section for the chosen kind. No kind chosen ⇒ only the picker;
    /// nothing is authored until the person picks a kind (the draft stays
    /// unresolvable, so Save stays closed).
    @ViewBuilder
    private var kindSection: some View {
        switch draft.payload?.kind {
        case .some(.text):
            textSection
        case .some(.image):
            imageSection
        case .some(.video):
            videoSection
        case .none:
            EmptyView()
        }
    }

    private var textSection: some View {
        TextField(L10n.str(InstructionSurfaceKeys.textPlaceholder, locale: locale),
                  text: Binding(
                    get: { draft.payload?.text ?? "" },
                    set: { draft.setText($0) }
                  ),
                  axis: .vertical)
            .font(.system(size: appearance.typography.bodyPointSize))
            .foregroundStyle(appearance.colors.textPrimary)
            .textFieldStyle(.roundedBorder)
            .disabled(!isEditable)
    }

    private var imageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .image(let pending) = draft.pendingMedia {
                Image(uiImage: pending)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(Text(L10n.str(
                        InstructionSurfaceKeys.imageAccessibility, locale: locale)))
            }
            Button {
                pickImage { image in
                    draft = InstructionEditorView.applyingPickedImage(
                        image, caption: draft.payload?.caption, to: draft)
                }
            } label: {
                Text(L10n.str(
                    InstructionEditorView.imageButtonKey(hasImage: hasImage), locale: locale))
                    .font(.system(size: appearance.typography.bodyPointSize,
                                  weight: .semibold))
                    .foregroundStyle(appearance.colors.accentForeground)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: DesignTokens.chipHeight)
                    .background(appearance.colors.accent)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius,
                                                style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!isEditable)
            captionField
        }
    }

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                capture.pick()
            } label: {
                Text(L10n.str(
                    InstructionEditorView.videoButtonKey(hasVideo: hasVideo), locale: locale))
                    .font(.system(size: appearance.typography.bodyPointSize,
                                  weight: .semibold))
                    .foregroundStyle(appearance.colors.accentForeground)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: DesignTokens.chipHeight)
                    .background(appearance.colors.accent)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius,
                                                style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!isEditable || capture.isBusy)

            Button {
                capture.record()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "record.circle")
                        .accessibilityHidden(true)
                    Text(L10n.str(InstructionSurfaceKeys.videoRecord, locale: locale))
                }
                .font(.system(size: appearance.typography.bodyPointSize,
                              weight: .semibold))
                .foregroundStyle(appearance.colors.accentForeground)
                .frame(maxWidth: .infinity)
                .frame(minHeight: DesignTokens.chipHeight)
                .background(appearance.colors.accent)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius,
                                            style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!isEditable || capture.isBusy)

            Text(L10n.str(InstructionSurfaceKeys.videoRecordingLimit, locale: locale))
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if hasVideo {
                captionField
            }

            // FR-RIE-024: the foreground-only limitation is stated where
            // the family chooses a video, never claimed away elsewhere.
            Text(L10n.str(InstructionSurfaceKeys.foregroundNote, locale: locale))
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var captionField: some View {
        TextField(L10n.str(InstructionSurfaceKeys.captionPlaceholder, locale: locale),
                  text: Binding(
                    get: { draft.payload?.caption ?? "" },
                    set: { draft.setCaption($0) }
                  ))
            .font(.system(size: appearance.typography.captionPointSize))
            .foregroundStyle(appearance.colors.textPrimary)
            .textFieldStyle(.roundedBorder)
            .disabled(!isEditable)
    }

    private var hasImage: Bool {
        if draft.payload?.filename != nil { return true }
        if case .image = draft.pendingMedia { return true }
        return false
    }

    private var hasVideo: Bool {
        if draft.payload?.filename != nil { return true }
        if case .video = draft.pendingMedia { return true }
        return false
    }

    /// One plain line for a capture stop and one for a save failure (the
    /// two are separate events and may both be shown).
    @ViewBuilder
    private var feedbackLines: some View {
        if let key = InstructionEditorView.feedbackKey(for: capture.state) {
            HStack(spacing: 8) {
                if case .validating = capture.state {
                    ProgressView()
                        .accessibilityHidden(true)
                }
                Text(L10n.str(key, locale: locale))
                    .font(.system(size: appearance.typography.captionPointSize))
                    .foregroundStyle(appearance.colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let saveFailureKey {
            Text(L10n.str(saveFailureKey, locale: locale))
                .font(.system(size: appearance.typography.captionPointSize))
                .foregroundStyle(appearance.statusForeground(DesignTokens.stateError))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var removeButton: some View {
        if InstructionEditorView.removeIsOffered(for: draft) {
            Button {
                draft.removeInstruction()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                        .accessibilityHidden(true)
                    Text(L10n.str(InstructionSurfaceKeys.remove, locale: locale))
                }
                .font(.system(size: appearance.typography.bodyPointSize,
                              weight: .semibold))
                .foregroundStyle(appearance.statusForeground(DesignTokens.stateError))
                .frame(maxWidth: .infinity)
                .frame(minHeight: DesignTokens.chipHeight)
                .appSurface(role: .card, cornerRadius: DesignTokens.bubbleCornerRadius)
            }
            .buttonStyle(.plain)
            .disabled(!isEditable)
        }
    }

    // MARK: - Actions (the only mutations)

    /// Save reports the one resolved commit and nothing else; the host owns
    /// persistence and maps any failure back through `saveFailureKey`.
    private func save() {
        guard let commit = draft.resolvedCommit else { return }
        onSave(commit)
    }

    private func cancelEditing() {
        capture.cancel()
        onCancel()
    }

    /// Takes the coordinator's accepted bytes exactly once: `consumeAccepted`
    /// clears `.ready` before returning, so the second call (the state
    /// change it causes, or a later appear) returns nil.
    private func consumeAcceptedVideoIfReady() {
        guard let accepted = capture.consumeAccepted() else { return }
        draft = InstructionEditorView.applyingAcceptedVideo(accepted, to: draft)
    }
}
