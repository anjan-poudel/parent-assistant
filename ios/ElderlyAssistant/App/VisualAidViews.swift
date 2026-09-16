import PhotosUI
import SwiftUI
import UIKit

// MARK: - Capture (PHPickerViewController)

/// Multi-select photo picker for a reminder's visual aids (photo-visual-aids
/// task, 2026-09-16).
///
/// `PHPickerViewController` deliberately, not the SwiftUI `PhotosPicker`:
/// it runs OUT OF PROCESS, so it needs no photo-library permission at all
/// (no `NSPhotoLibraryUsageDescription`, no access prompt in front of an
/// elderly user) and it hands back only the images the user picked. Camera
/// capture is out of scope this round; the picker covers "photograph the box
/// once, attach it to the reminder".
///
/// The picker owns nothing but selection: each returned `UIImage` goes to
/// `VisualAidStore.save`, which is the single place that decides stored
/// size (≤1600px) and encoding (JPEG 0.8).
struct VisualAidPhotoPicker: UIViewControllerRepresentable {

    /// How many photos may still be added (the store's cap minus what the
    /// entry already carries). Callers hide the action at the cap; this
    /// clamps to at least 1 so a stale value can never make the picker
    /// un-selectable.
    let selectionLimit: Int
    /// Called once with the picked images IN SELECTION ORDER. Empty results
    /// (the user cancelled) never reach this — cancellation just dismisses.
    let onPicked: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = max(1, selectionLimit)
        // Keep the original encoding; our own downscale is the one place
        // that decides the stored representation.
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onPicked: ([UIImage]) -> Void

        init(onPicked: @escaping ([UIImage]) -> Void) {
            self.onPicked = onPicked
        }

        func picker(_ picker: PHPickerViewController,
                    didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else { return }
            Self.loadImages(from: results.map(\.itemProvider), completion: onPicked)
        }

        /// Loads every provider concurrently but reports them in SELECTION
        /// order (a dictionary built from completion order would shuffle
        /// the pages of the firing screen). Providers that yield no image
        /// are dropped rather than replaced with a placeholder.
        private static func loadImages(from providers: [NSItemProvider],
                                       completion: @escaping ([UIImage]) -> Void) {
            var slots = [UIImage?](repeating: nil, count: providers.count)
            let lock = NSLock()
            let group = DispatchGroup()
            for (index, provider) in providers.enumerated()
            where provider.canLoadObject(ofClass: UIImage.self) {
                group.enter()
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    lock.lock()
                    slots[index] = object as? UIImage
                    lock.unlock()
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                completion(slots.compactMap { $0 })
            }
        }
    }
}

// MARK: - Elder-facing presentation (the reminder firing screen)

/// One reminder's photos, full screen, for the person the reminder is FOR
/// (photo-visual-aids task, 2026-09-16).
///
/// The design brief for this screen: the image LARGE above the reminder
/// text, one image at a time, swipeable with an indicator when there is
/// more than one, caption optional below. Every size and colour comes from
/// `DesignTokens`, and the page rules come from `VisualAidDisplayState`
/// (unit-tested independently of this view).
///
/// Modelled on `TimerAlarmScreen` — the app's one existing full-screen
/// elder-facing surface — including the top-left chevron escape path, so
/// the gesture is the same on every non-Home screen.
///
/// Both reminder systems use this one screen (medication-visual-aids task,
/// 2026-09-16): a routine reminder passes only its title, while a medication
/// DOSE passes the dose line and the "I took it" action through `footer` —
/// the photo pager, its disk loading, the caption, the page indicator and
/// the escape chevron are shared rather than copied, so a fix to any of
/// them fixes both the walk reminder and the medicine reminder.
struct ReminderVisualAidScreen<Footer: View>: View {
    let entryId: UUID
    let title: String
    let aids: [VisualAid]
    /// The photo store that owns this entry's aids: the shared routine
    /// store (`AppCoordinator.visualAidStore`) for a routine reminder, the
    /// medication store for a dose. The caller picks — the screen only
    /// reads through it.
    let store: VisualAidStore
    /// The display language for the page indicator; the app language, not
    /// the device locale — same rule as every other string in the app.
    let locale: Locale
    let onClose: () -> Void
    /// Extra content below the reminder's own text (the caption and page
    /// indicator come first). `EmptyView` for a routine reminder; the dose
    /// line + acknowledge action on the medication firing screen.
    @ViewBuilder let footer: Footer

    @State private var display: VisualAidDisplayState
    /// Loaded ONCE in `.task`, never in `body`: this screen must not touch
    /// the disk while it draws (the same rule `RemindersView` documents).
    @State private var images: [UUID: UIImage] = [:]

    init(entryId: UUID, title: String, aids: [VisualAid],
         store: VisualAidStore, locale: Locale, onClose: @escaping () -> Void,
         @ViewBuilder footer: () -> Footer) {
        self.entryId = entryId
        self.title = title
        self.aids = aids
        self.store = store
        self.locale = locale
        self.onClose = onClose
        self.footer = footer()
        _display = State(initialValue: VisualAidDisplayState(aids: aids))
    }

    /// The image page for `aid`, or nil when it could not be read — a
    /// deleted or corrupt file degrades to the text-only screen rather
    /// than an empty frame.
    private func image(for aid: VisualAid) -> UIImage? { images[aid.id] }

    private var currentImage: UIImage? {
        display.current.flatMap(image(for:))
    }

    var body: some View {
        ZStack {
            DesignTokens.background.ignoresSafeArea()
            VStack(spacing: 16) {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(minWidth: DesignTokens.minTapTargetSize,
                                   minHeight: DesignTokens.minTapTargetSize)
                            .background(DesignTokens.accent)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("common.close"))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                if display.showsImage, currentImage != nil {
                    imagePager
                }

                VStack(spacing: 10) {
                    Text(title)
                        .font(DesignTokens.greetingFont(size: DesignTokens.titlePointSize))
                        .foregroundStyle(DesignTokens.textPrimary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    if let caption = display.currentCaption {
                        Text(caption)
                            .font(.system(size: DesignTokens.minBodyPointSize))
                            .foregroundStyle(DesignTokens.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }

                    // "Photo 2 of 3" — hidden for a lone photo ("1 of 1" is
                    // noise). Rendered as real text rather than the page
                    // dots' default style: at caption size it is legible to
                    // the person this screen is for.
                    if let indicator = display.indicatorText(locale: locale),
                       currentImage != nil {
                        Text(indicator)
                            .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                            .foregroundStyle(DesignTokens.textSecondary)
                            .accessibilityLabel(Text(indicator))
                    }

                    // The caller's own content — nothing at all for a
                    // routine reminder, the dose line and the elder's
                    // acknowledge action for a medication dose.
                    footer
                }
                .padding(.bottom, 24)
            }
        }
    }

    /// One page per aid, swipeable. The selection binding writes through
    /// `VisualAidDisplayState.select`, so the clamping rules stay in the
    /// tested type; the page dots are off because the app draws its own
    /// larger indicator above.
    private var imagePager: some View {
        TabView(selection: Binding(
            get: { display.index },
            set: { display.select($0) }
        )) {
            ForEach(Array(aids.enumerated()), id: \.element.id) { index, aid in
                Group {
                    if let image = image(for: aid) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DesignTokens.card)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
                .padding(.horizontal, 20)
                .accessibilityLabel(Text("visualAid.title"))
                .accessibilityHint(Text(aid.caption ?? ""))
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(maxHeight: .infinity)
        .task(id: entryId) {
            var loaded: [UUID: UIImage] = [:]
            for aid in aids {
                if let image = store.load(aid, for: entryId) {
                    loaded[aid.id] = image
                }
            }
            images = loaded
        }
    }
}

extension ReminderVisualAidScreen where Footer == EmptyView {
    /// The routine case: photos, title, caption, indicator, close. Keeps
    /// every existing call site (and the pre-medication behaviour) intact.
    init(entryId: UUID, title: String, aids: [VisualAid],
         store: VisualAidStore, locale: Locale, onClose: @escaping () -> Void) {
        self.init(entryId: entryId, title: title, aids: aids, store: store,
                  locale: locale, onClose: onClose, footer: { EmptyView() })
    }
}

/// What the app is presenting right now because a reminder fired with
/// photos attached. `Identifiable` so it can drive a `fullScreenCover(item:)`.
struct FiredRoutineVisualAids: Identifiable, Equatable {
    let entryId: UUID
    let title: String
    let aids: [VisualAid]
    var id: UUID { entryId }
}

/// Host for the fired-reminder screen, mounted at the app root next to
/// `TimerAlarmOverlay`. Transparent while nothing has fired; presents the
/// screen the moment a routine reminder with photos is delivered in the
/// foreground.
struct RoutineVisualAidOverlay: View {
    let presentation: FiredRoutineVisualAids?
    let store: VisualAidStore
    let locale: Locale
    let onClose: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .fullScreenCover(item: Binding(
                get: { presentation },
                set: { newValue in if newValue == nil { onClose() } }
            )) { fired in
                ReminderVisualAidScreen(
                    entryId: fired.entryId,
                    title: fired.title,
                    aids: fired.aids,
                    store: store,
                    locale: locale,
                    onClose: onClose
                )
            }
    }
}

// MARK: - Photo editor (thumbnails + Add photo)

/// Manage the photos on one reminder: a row of thumbnails (tap to view
/// full screen), a caption per photo, and "Add photo".
///
/// Reached from the Reminders leaf's routine rows and from the Settings
/// medication schedule's rows (medication-visual-aids task, 2026-09-16) —
/// both reminder systems have the same surface, not two. The caller passes
/// the entry id, the title to display, the current aids, the store that
/// owns them and the save path the edits persist through.
///
/// For routines this is the surface the brief called the "reminder
/// add/edit screen" — routines have no SwiftUI editor today (they are
/// seeded, voice-created or calendar-synced), so this sheet is the photo
/// half of one. For medication it hangs off the schedule editor's rows,
/// the surface where a medication entry is edited.
///
/// Edits persist IMMEDIATELY through the caller's save path (`...VisualAids`)
/// — same behaviour as the routine enable toggle: there is no draft state
/// to lose if the sheet is swiped away.
struct ReminderVisualAidEditorView: View {
    /// The ENTRY this reminder's photos belong to. The caller's store is
    /// keyed by it, and it is all the sheet needs to render and save.
    let entryId: UUID
    /// What the sheet is titled: a routine's display title, or a
    /// medication's name.
    let title: String
    let store: VisualAidStore
    let locale: Locale
    let onSave: ([VisualAid]) -> Void
    let onClose: () -> Void

    @State private var aids: [VisualAid]
    @State private var images: [UUID: UIImage] = [:]
    @State private var captionDrafts: [UUID: String] = [:]
    @State private var isPickingPhotos = false
    @State private var fullScreenAid: VisualAid?

    init(entryId: UUID, title: String, aids: [VisualAid], store: VisualAidStore,
         locale: Locale, onSave: @escaping ([VisualAid]) -> Void,
         onClose: @escaping () -> Void) {
        self.entryId = entryId
        self.title = title
        self.store = store
        self.locale = locale
        self.onSave = onSave
        self.onClose = onClose
        _aids = State(initialValue: aids)
        _captionDrafts = State(initialValue: Dictionary(
            uniqueKeysWithValues: aids.map { ($0.id, $0.caption ?? "") }
        ))
    }

    private var remainingSlots: Int { VisualAidStore.maxPerEntry - aids.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if aids.isEmpty {
                        Text("visualAid.addHint")
                            .font(.system(size: DesignTokens.minBodyPointSize))
                            .foregroundStyle(DesignTokens.textSecondary)
                    }
                    ForEach(aids) { aid in
                        thumbnailRow(aid)
                    }
                    if remainingSlots > 0 {
                        addPhotoButton
                    }
                }
                .padding(20)
            }
            .background(DesignTokens.background)
            .navigationTitle(Text(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        applyCaptionDrafts()
                        onClose()
                    } label: {
                        Text("common.close")
                            .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    }
                }
            }
        }
        .task(id: entryId) { loadImages() }
        .sheet(isPresented: $isPickingPhotos) {
            VisualAidPhotoPicker(selectionLimit: remainingSlots) { picked in
                add(picked)
            }
        }
        .fullScreenCover(item: $fullScreenAid) { aid in
            ReminderVisualAidScreen(
                entryId: entryId,
                title: title,
                // The viewer pages through what is on the reminder NOW,
                // including an aid just added in this sheet.
                aids: aids,
                store: store,
                locale: locale,
                onClose: { fullScreenAid = nil }
            )
        }
    }

    private func thumbnailRow(_ aid: VisualAid) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    fullScreenAid = aid
                } label: {
                    Group {
                        if let image = images[aid.id] {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: "photo")
                                .font(.system(size: 28))
                                .foregroundStyle(DesignTokens.textSecondary)
                        }
                    }
                    .frame(width: 88, height: 88)
                    .background(DesignTokens.card)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("visualAid.title"))

                TextField("visualAid.captionPlaceholder",
                          text: Binding(
                            get: { captionDrafts[aid.id] ?? "" },
                            set: { captionDrafts[aid.id] = $0 }
                          ))
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .textFieldStyle(.roundedBorder)

                Button {
                    remove(aid)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 22))
                        .foregroundStyle(DesignTokens.stateError)
                        .frame(minWidth: DesignTokens.minTapTargetSize,
                               minHeight: DesignTokens.minTapTargetSize)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("visualAid.remove"))
            }
        }
    }

    private var addPhotoButton: some View {
        Button {
            isPickingPhotos = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 24, weight: .semibold))
                Text("visualAid.add")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
            }
            .foregroundStyle(DesignTokens.accent)
            .frame(maxWidth: .infinity)
            .frame(minHeight: DesignTokens.minTapTargetSize + 12)
            .background(DesignTokens.setupReminder)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Mutations (each persists immediately)

    /// Saves whichever photos the picker returned, up to the cap. A save
    /// that fails (no bitmap, unusable sandbox) is dropped silently — a
    /// visual aid is a nicety, never an error dialog in front of an
    /// elderly user.
    private func add(_ picked: [UIImage]) {
        var updated = aids
        for image in picked where updated.count < VisualAidStore.maxPerEntry {
            if let aid = store.save(image, for: entryId) {
                updated.append(aid)
                captionDrafts[aid.id] = ""
            }
        }
        persist(updated)
        loadImages()
    }

    private func remove(_ aid: VisualAid) {
        store.delete(aid, for: entryId)
        let updated = aids.filter { $0.id != aid.id }
        captionDrafts[aid.id] = nil
        images[aid.id] = nil
        persist(updated)
    }

    /// Commits the caption fields. Called on Close (and nowhere per
    /// keystroke — that would be one encrypted write per character).
    private func applyCaptionDrafts() {
        let updated = aids.map { aid -> VisualAid in
            var copy = aid
            let draft = (captionDrafts[aid.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            copy.caption = draft.isEmpty ? nil : draft
            return copy
        }
        persist(updated)
    }

    private func persist(_ updated: [VisualAid]) {
        aids = updated
        onSave(updated)
    }

    private func loadImages() {
        var loaded: [UUID: UIImage] = [:]
        for aid in aids {
            if let image = store.load(aid, for: entryId) {
                loaded[aid.id] = image
            }
        }
        images = loaded
    }
}
