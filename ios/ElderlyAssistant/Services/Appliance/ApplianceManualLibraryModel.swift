import UIKit

/// View-model for the saved-manuals library (2026-09-06,
/// local-cache-manuals): the cache entries that carry a stored photo,
/// most recently saved first, filtered as the elder types.
///
/// "Saved manual" = one cached entry WITH its downscaled photo — that is
/// the record the step-card result UI can re-render from cache with zero
/// network. Legacy entries cached before this feature (no photo) still
/// dedupe new requests by key, but cannot be re-rendered, so they are not
/// listed here; the next time the same appliance is answered they come
/// back as a full manual.
///
/// Search (as-you-type, no submit step — the elder's phone-contacts
/// search works the same way) runs over the appliance name, its
/// brand/model/category identity, and the question the manual answers.
@MainActor
final class ApplianceManualLibraryModel: ObservableObject {

    /// One library row.
    struct Manual: Identifiable {
        let id: UUID
        /// Appliance name (identity.displayName), category as fallback.
        let title: String
        let brand: String?
        let model: String?
        let category: String
        /// The question this manual answers; nil = general how-to-use.
        let question: String?
        /// When the manual was saved.
        let createdAt: Date
        /// The stored downscaled photo; nil only when the file is
        /// unreadable (defensive — rows still open, image-less).
        let thumbnail: UIImage?
    }

    @Published private(set) var manuals: [Manual] = []
    @Published var query: String = ""

    private let cache: ApplianceCache

    init(cache: ApplianceCache) {
        self.cache = cache
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True while a search is active (drives the empty-vs-no-results
    /// distinction — an empty LIBRARY and a query with no match are
    /// different truths).
    var isSearching: Bool { !trimmedQuery.isEmpty }

    /// The rows to show: everything, or the query's matches.
    var visibleManuals: [Manual] {
        Self.filter(manuals, query: trimmedQuery)
    }

    /// Pure filter over the searchable fields — directly unit-testable.
    static func filter(_ manuals: [Manual], query: String) -> [Manual] {
        guard !query.isEmpty else { return manuals }
        return manuals.filter { manual in
            let haystacks = [manual.title,
                             manual.brand ?? "",
                             manual.model ?? "",
                             manual.category,
                             manual.question ?? ""]
            return haystacks.contains { $0.localizedStandardContains(query) }
        }
    }

    /// Reloads from the cache (most recently saved first). Cheap enough
    /// for a synchronous reload on library open — ≤40 small entries, each
    /// with a ~256px JPEG.
    func reload() {
        manuals = cache.allEntries().compactMap(manual(from:))
    }

    /// Deletes one manual from the cache (entry + its stored photo).
    func delete(manualID: UUID) {
        guard cache.delete(entryID: manualID) else { return }
        manuals.removeAll { $0.id == manualID }
    }

    private func manual(from entry: ApplianceCache.Entry) -> Manual? {
        // No stored photo → not re-renderable → not a listed manual.
        guard entry.imageFileName != nil else { return nil }
        let identity = entry.guidance.identity
        let title = identity.displayName.isEmpty ? identity.category : identity.displayName
        let thumbnail = cache.imageJPEG(entryID: entry.id).flatMap(UIImage.init(data:))
        return Manual(id: entry.id,
                      title: title,
                      brand: identity.brand,
                      model: identity.model,
                      category: identity.category,
                      question: entry.question,
                      createdAt: entry.createdAt,
                      thumbnail: thumbnail)
    }
}
