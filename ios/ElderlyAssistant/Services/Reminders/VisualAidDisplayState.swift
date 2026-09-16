import Foundation

/// What the reminder-firing screen shows for one entry's visual aids
/// (photo-visual-aids task, 2026-09-16): ONE image at a time, its caption
/// below, and a "Photo 2 of 3" indicator when the entry carries more than
/// one.
///
/// Kept as a value type with no view and no disk access so the paging
/// rules — clamping, wrap-around, when an indicator exists at all — are
/// unit-testable without a simulator screen. The view owns only the
/// `TabView` selection binding and the `VisualAidStore` load; every
/// decision about WHAT to show lives here.
struct VisualAidDisplayState: Equatable {

    /// The entry's aids, in the order the caregiver added them.
    let aids: [VisualAid]
    /// Index of the aid on screen. Always valid for a non-empty `aids`
    /// (see `init`), meaningless-but-zero when empty.
    private(set) var index: Int

    init(aids: [VisualAid], index: Int = 0) {
        self.aids = aids
        self.index = aids.isEmpty ? 0 : min(max(index, 0), aids.count - 1)
    }

    init(entry: RoutineEntry) {
        self.init(aids: entry.visualAids)
    }

    /// The medication side of the same screen (medication-visual-aids
    /// task, 2026-09-16): a dose fires with the box photo large above the
    /// dose text, and the paging rules are identical — one image at a
    /// time, an indicator only when there is more than one, a clamped
    /// index. Keeping the medication case on THIS type is the point: the
    /// safety-critical dose path gets the same tested paging behaviour
    /// rather than a second copy of it.
    init(medicationEntry: MedicationEntry) {
        self.init(aids: medicationEntry.visualAids)
    }

    // MARK: - Queries

    /// Nothing to render — the firing screen falls back to text alone,
    /// which is the state of every entry without photos.
    var isEmpty: Bool { aids.isEmpty }

    var count: Int { aids.count }

    /// More than one aid: the screen shows a page indicator and accepts a
    /// swipe. A single aid gets no indicator — "1 of 1" is noise.
    var hasMultiple: Bool { aids.count > 1 }

    /// The aid currently on screen, nil when there are none.
    var current: VisualAid? {
        aids.indices.contains(index) ? aids[index] : nil
    }

    /// Caption for the CURRENT aid, nil when absent or blank — a
    /// whitespace-only caption must not reserve a blank line under the
    /// photo.
    var currentCaption: String? {
        guard let caption = current?.caption else { return nil }
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether the large image belongs on screen at all.
    var showsImage: Bool { !isEmpty }

    /// "Photo 2 of 3" for the indicator; nil when there is only one aid
    /// (or none), so callers render the indicator purely on
    /// `indicatorText != nil`.
    func indicatorText(locale: Locale) -> String? {
        guard hasMultiple else { return nil }
        return L10n.fmt("visualAid.pageIndicator", locale: locale, index + 1, count)
    }

    // MARK: - Paging

    /// Next aid, wrapping past the last back to the first — a swipe off
    /// the end of three photos should land somewhere, not dead-end.
    mutating func advance() {
        guard !aids.isEmpty else { return }
        index = (index + 1) % aids.count
    }

    /// Previous aid, wrapping past the first to the last.
    mutating func goBack() {
        guard !aids.isEmpty else { return }
        index = (index - 1 + aids.count) % aids.count
    }

    /// Jump to an explicit page (a `TabView` selection write, or a
    /// thumbnail tap). Out-of-range values clamp instead of trapping.
    mutating func select(_ newIndex: Int) {
        guard !aids.isEmpty else { return }
        index = min(max(newIndex, 0), aids.count - 1)
    }
}
