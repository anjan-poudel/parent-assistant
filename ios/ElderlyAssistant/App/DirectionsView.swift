import SwiftUI
import UIKit
import AVFoundation
import Speech

/// Pure list model for the Directions leaf (directions-screen task,
/// 2026-09-07) — what the screen shows and how it filters, kept free of
/// view state so the matching/grouping rules are unit-testable without a
/// view host (same pattern as `UnifiedContactSearch` / `DirectionsRoute`).
enum DirectionsScreenList {

    /// The three labelled groups the saved navigation targets fall into
    /// (Home / Relatives / Important — the user's own ordering). `allCases`
    /// order IS the on-screen order. Headers resolve through the SHARED
    /// settings keys, so one string drives the Settings editors and this
    /// screen (the map-app-name rule: no second copy to drift).
    enum Group: Int, CaseIterable, Equatable {
        case homes
        case relatives
        case importantPlaces

        var headerKey: String {
            switch self {
            case .homes: return "settings.places.category.home"
            case .relatives: return "settings.family.title"
            case .importantPlaces: return "settings.places.category.important"
            }
        }
    }

    /// One destination row — the on-screen slice of a `SavedPlace` or an
    /// addressed `FamilyContact`, carrying what the row shows AND the id
    /// the navigation executor resolves.
    struct Row: Equatable, Identifiable {
        enum Kind: Equatable {
            case savedPlace
            case relative
        }

        /// Namespaced stable identity: place ids and contact ids are both
        /// UUIDs from independent stores, so a raw id could collide across
        /// the two namespaces — the prefix makes every row id unique.
        var id: String {
            let namespace = kind == .savedPlace ? "place" : "relative"
            return "\(namespace)-\(targetID.uuidString)"
        }

        let kind: Kind
        /// The backing store's id — the argument the coordinator's
        /// navigation executor resolves (`.place(id)` / `.familyContact(id)`).
        let targetID: UUID
        let group: Group
        let name: String
        let address: String
        /// The contact's relationship ("छोरी", "son"…) — nil for places.
        let relationship: String?
    }

    /// One labelled group of rows on screen.
    struct Section: Equatable, Identifiable {
        let group: Group
        let rows: [Row]
        var id: Group { group }
    }

    /// Every navigation target the leaf lists: ALL saved places (homes
    /// and important) plus every family contact that carries a NON-EMPTY
    /// address. Mirrors `AppCoordinator.navigationCandidates`'s filter —
    /// an entry with no drivable address must not appear where its only
    /// action would dead-end.
    static func allRows(places: [SavedPlace],
                        contacts: [FamilyContact]) -> [Row] {
        var rows: [Row] = []
        for place in places
        where !place.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let group: Group = place.category == .home ? .homes : .importantPlaces
            rows.append(Row(kind: .savedPlace, targetID: place.id, group: group,
                            name: place.name, address: place.address,
                            relationship: nil))
        }
        for contact in contacts {
            guard let address = contact.address,
                  !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            let relationship = contact.relationship
                .trimmingCharacters(in: .whitespacesAndNewlines)
            rows.append(Row(kind: .relative, targetID: contact.id, group: .relatives,
                            name: contact.name, address: address,
                            relationship: relationship.isEmpty ? nil : contact.relationship))
        }
        return rows
    }

    /// Whether `row` answers the typed/spoken query — the exact tier
    /// ladder `UnifiedContactSearch.familyMatches` uses, applied to the
    /// row's name and relationship:
    ///  1. normalized name equals the normalized query (exact), then
    ///  2. the query AND the stored relationship share one
    ///     `ContactResolver` anchor — the cross-script and synonym bridge
    ///     ("daughter" ↔ "छोरी", "बहिनी" ↔ "दिदी" share no substring but
    ///     both anchor on "sister"), then
    ///  3. case- and diacritic-insensitive containment over the RAW name
    ///     or relationship. `String.range(of:options:)` matches on
    ///     EXTENDED GRAPHEME CLUSTERS, so Devanagari virama/matra fusions
    ///     stay intact (the 2026-09-07 grapheme lesson — "खोज्नुहोस्"
    ///     does not contain "खोज" as substring in naive scalar terms, and
    ///     Swift's own APIs are the safe way to ask).
    /// An empty/whitespace query matches everything. Deliberately NO
    /// Devanagari↔Latin transliteration anywhere (same rule as the
    /// contact search: lossy folding would merge different names).
    static func matches(query rawQuery: String, row: Row) -> Bool {
        let needle = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        let normalizedQuery = NepaliTextNormalizer.normalize(needle)

        if NepaliTextNormalizer.normalize(row.name) == normalizedQuery { return true }

        if let relationship = row.relationship,
           let queryAnchor = ContactResolver.relationshipAnchor(in: normalizedQuery),
           let rowAnchor = ContactResolver.relationshipAnchor(
               in: NepaliTextNormalizer.normalize(relationship)),
           queryAnchor == rowAnchor {
            return true
        }

        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if row.name.range(of: needle, options: options) != nil { return true }
        if let relationship = row.relationship,
           relationship.range(of: needle, options: options) != nil {
            return true
        }
        return false
    }

    /// `rows` reduced to the ones matching `query` — the as-you-type
    /// filter. Everything passes when the query is empty.
    static func filtered(_ rows: [Row], query: String) -> [Row] {
        rows.filter { matches(query: query, row: $0) }
    }

    /// Splits `rows` into the labelled sections (homes → relatives →
    /// important), dropping groups that have nothing to show. The list
    /// keeps this order whether the whole list or a search result is
    /// rendered — stable placement beats re-ranking for a short list.
    static func sections(rows: [Row]) -> [Section] {
        Group.allCases.compactMap { group in
            let inGroup = rows.filter { $0.group == group }
            return inGroup.isEmpty ? nil : Section(group: group, rows: inGroup)
        }
    }
}

// MARK: - The Directions leaf

/// Directions leaf (directions-screen task, 2026-09-07): EVERY saved
/// navigation target — saved places (homes + important) and family
/// contacts that carry an address — on one warm list, each row's big
/// "जाऊ" button launching the SAME navigation executor the voice route
/// drives (map policy → geocode → open → honest spoken lines, via the
/// coordinator's thin wrappers — no duplicated open logic). A big search
/// pill with a one-shot mic button (the Phone leaf's capture pattern)
/// filters the list as you type; with nothing saved, an honest card
/// deep-links into Settings → Places and maps, where the targets are
/// created.
struct DirectionsView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.scenePhase) private var scenePhase

    @State private var searchText = ""

    /// One-shot mic-capture phase for the search pill's mic button — the
    /// `CallView.MicPhase` pattern: idle → listening → idle/failed.
    private enum MicPhase { case idle, listening, failed }
    @State private var micPhase: MicPhase = .idle
    /// True once speech/mic permission is denied — the button is honest
    /// dead for this visit (Settings can reverse it; next visit re-checks).
    @State private var micHidden = false

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every row the leaf can show, built fresh from the coordinator's
    /// @Published stores — a place saved in Settings while this leaf was
    /// on the stack re-renders the list on return; nothing cached here.
    private var rows: [DirectionsScreenList.Row] {
        DirectionsScreenList.allRows(places: coordinator.savedPlaces,
                                     contacts: coordinator.familyContacts)
    }

    private var sections: [DirectionsScreenList.Section] {
        DirectionsScreenList.sections(
            rows: DirectionsScreenList.filtered(rows, query: trimmedQuery))
    }

    private var hasAnyTarget: Bool { !rows.isEmpty }

    var body: some View {
        LeafScreen(titleKey: "directions.title") {
            VStack(spacing: 10) {
                searchPill
                micCaption
                listArea
            }
        }
        .onAppear { updateMicVisibility() }
        // Returning from Settings (a denial reversed, a place added)
        // re-checks permission visibility; the rows re-read on their own.
        .onChange(of: scenePhase) { phase in
            if phase == .active { updateMicVisibility() }
        }
        .onDisappear {
            // Never leave the voice pipeline suspended and the mic open:
            // a leaf the user walked away from must not keep listening.
            // The capture completion (fires on cancel) restarts the
            // pipeline.
            if micPhase == .listening {
                coordinator.cancelSearchPhraseCapture()
            }
            micPhase = .idle
        }
        // Empty-state deep link (2026-09-07): the "Add place" card pushes
        // PlacesSettingsView through the SAME type-erased NavigationStack
        // Home owns, value-based like every other push. Only `.places` is
        // reachable from this leaf — the other sections map to nothing.
        .navigationDestination(for: SettingsView.SettingsSection.self) { section in
            switch section {
            case .places: PlacesSettingsView()
            default: EmptyView()
            }
        }
    }

    // MARK: Search pill (voice activation)

    /// Big search pill (≥44pt, body-size text, warm card) — the Phone
    /// leaf's pill. Search runs as the user types — no submit step to
    /// fumble. The mic button rides inside the pill; a spoken phrase
    /// fills the field and the list filters on it like typing.
    private var searchPill: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(DesignTokens.textSecondary)
            TextField("directions.search.placeholder", text: $searchText)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if micButtonVisible {
                micButton
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: DesignTokens.minTapTargetSize)
        .background(DesignTokens.card)
        .clipShape(Capsule())
    }

    /// In-pill voice-search button (2026-09-07) — one shot captures a
    /// place/person name into the search field, exactly like the Phone
    /// leaf's mic. ≥44pt tap target (DesignTokens floor). While listening
    /// it becomes the stop control; the caption below says what the mic
    /// is doing.
    private var micButton: some View {
        let listening = micPhase == .listening
        return Button(action: micTapped) {
            Image(systemName: listening ? "stop.fill" : "mic.fill")
                // Caption token (DESIGN-REVIEW): 18pt floor, Dynamic Type
                // aware — the 30pt circle below grows with it via
                // `minHeight`/`minWidth` so the glyph can never clip.
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                .foregroundColor(listening ? .white : DesignTokens.accent)
                .frame(width: 30, height: 30)
                .background(listening ? DesignTokens.accent : DesignTokens.background)
                .clipShape(Circle())
        }
        .frame(minWidth: DesignTokens.minTapTargetSize,
               minHeight: DesignTokens.minTapTargetSize)
        .accessibilityLabel(Text(LocalizedStringKey(
            listening ? "directions.search.micStopLabel" : "directions.search.micLabel")))
    }

    /// True when the mic button may be shown: speech and mic permission
    /// are not dead. `.notDetermined` counts as visible — the ask happens
    /// at the tap (point of use); a denial flips `micHidden` for the rest
    /// of this visit.
    private var micButtonVisible: Bool {
        guard !micHidden else { return false }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized, .notDetermined: break
        case .denied, .restricted: return false
        @unknown default: return false
        }
        if micRecordPermissionDenied() { return false }
        return true
    }

    private func updateMicVisibility() {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied, .restricted: micHidden = true
        default: break
        }
        if micRecordPermissionDenied() { micHidden = true }
    }

    private func micRecordPermissionDenied() -> Bool {
        if #available(iOS 17.0, *) {
            return AVAudioApplication.shared.recordPermission == .denied
        }
        return AVAudioSession.sharedInstance().recordPermission == .denied
    }

    /// Tap on the mic / stop button. Idle → start listening. Listening →
    /// stop (the capture completion restores the voice pipeline and
    /// returns the phase to idle). Failed → clear the caption and start
    /// again — one tap retries, no intermediate step.
    private func micTapped() {
        switch micPhase {
        case .idle, .failed:
            micPhase = .listening
            startMicCapture()
        case .listening:
            coordinator.cancelSearchPhraseCapture()
        }
    }

    private func startMicCapture() {
        // DirectionsView is a struct — the @State mutations below are
        // captured through the binding; the closure only outlives the
        // view briefly while the one-shot capture runs (the CallView
        // pattern).
        coordinator.startSearchPhraseCapture { result in
            switch result {
            case .success(let text):
                self.micPhase = .idle
                // The as-you-type filter picks the transcript up from
                // here — the spoken place name lands in the field.
                self.searchText = text
            case .failure(let failure):
                switch failure {
                case .notAuthorized:
                    // Denied at the point of use — the button is honest
                    // dead for this visit (Settings can reverse it).
                    self.micHidden = true
                    self.micPhase = .idle
                case .cancelled, .busy:
                    // User tapped stop, or the assistant is mid-turn —
                    // both transient, both silent.
                    self.micPhase = .idle
                case .noSpeech, .audioUnavailable, .noAudioInput,
                     .recognitionFailed:
                    self.micPhase = .failed
                }
            }
        }
    }

    /// What the mic is doing right now — a caption under the pill while
    /// listening or after a failed attempt. Silent otherwise.
    @ViewBuilder
    private var micCaption: some View {
        switch micPhase {
        case .listening:
            Text(L10n.str("directions.search.micListening", locale: coordinator.activeLocale))
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundColor(DesignTokens.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
        case .failed:
            Text(L10n.str("directions.search.micFailed", locale: coordinator.activeLocale))
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundColor(DesignTokens.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
        case .idle:
            EmptyView()
        }
    }

    // MARK: List / empty states

    @ViewBuilder
    private var listArea: some View {
        if !hasAnyTarget {
            emptyCard
        } else if sections.isEmpty {
            noResultsCard
        } else {
            VStack(spacing: 12) {
                ForEach(sections) { section in
                    groupSection(section)
                }
            }
        }
    }

    private func groupSection(_ section: DirectionsScreenList.Section) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringKey(section.group.headerKey))
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                .foregroundColor(DesignTokens.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            ForEach(section.rows) { row in
                destinationRow(row)
            }
        }
    }

    /// One warm card: avatar/glyph, the name (+ relationship and address
    /// lines), and the big round जाऊ button — the card's only action, so
    /// a mis-tap can never launch a drive.
    private func destinationRow(_ row: DirectionsScreenList.Row) -> some View {
        HStack(alignment: .center, spacing: 12) {
            avatar(for: row)
                .accessibilityHidden(true)   // row texts carry the meaning
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name)
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(DesignTokens.textPrimary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                if let relationship = row.relationship {
                    Text(relationship)
                        .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                        .foregroundColor(DesignTokens.accent)
                        .lineLimit(1)
                }
                Text(row.address)
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            goButton(for: row)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }

    /// The row's leading circle: a place glyph in the directions badge
    /// tint, or the person's own initial avatar for relatives (the same
    /// identity visual the dock's Call tile and the Phone leaf use).
    /// Hidden from VoiceOver — the row's own texts carry the meaning.
    @ViewBuilder
    private func avatar(for row: DirectionsScreenList.Row) -> some View {
        switch row.kind {
        case .savedPlace:
            IconBadge(systemImage: row.group == .homes ? "house.fill" : "mappin.and.ellipse",
                      tint: .directions, diameter: 44)
        case .relative:
            FaceAvatar(name: row.name, diameter: 44)
        }
    }

    /// The row's big round "जाऊ" — the whole card's one tap target (≥44pt
    /// by a wide margin). Drives through the coordinator's navigation
    /// wrappers, which reuse the exact executor the voice route uses.
    /// VoiceOver reads what the tap does ("Let's go to …"), never the
    /// bare Devanagari verb.
    private func goButton(for row: DirectionsScreenList.Row) -> some View {
        Button {
            switch row.kind {
            case .savedPlace:
                coordinator.navigateToPlace(id: row.targetID)
            case .relative:
                coordinator.navigateToFamilyContact(id: row.targetID)
            }
        } label: {
            Text(LocalizedStringKey("directions.goLabel"))
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 56, height: 56)
                .background(DesignTokens.accent)
                .clipShape(Circle())
                .shadow(color: DesignTokens.accent.opacity(0.35), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L10n.fmt("directions.goAccessibility",
                                          locale: coordinator.activeLocale, row.name)))
    }

    /// Honest empty state: nothing drivable is saved anywhere — the card
    /// says where targets come from and its button deep-links into the
    /// Settings section that creates them (one tap, no hunting).
    private var emptyCard: some View {
        VStack(spacing: 14) {
            IconBadge(systemImage: "map.fill", tint: .directions, diameter: 72)
            Text(LocalizedStringKey("settings.places.empty"))
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundColor(DesignTokens.textPrimary)
                .multilineTextAlignment(.center)
            Text(LocalizedStringKey("directions.empty.body"))
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            NavigationLink(value: SettingsView.SettingsSection.places) {
                Text(LocalizedStringKey("settings.places.add"))
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .frame(height: 52)
                    .background(DesignTokens.accent)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(LocalizedStringKey("directions.empty.addAccessibility")))
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }

    /// Search found nothing — say so plainly; keep typing or try another
    /// name is the next move (never a silent blank list).
    private var noResultsCard: some View {
        Text(L10n.fmt("directions.search.noResults",
                      locale: coordinator.activeLocale, trimmedQuery))
            .font(.system(size: DesignTokens.minBodyPointSize))
            .foregroundColor(DesignTokens.textSecondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(DesignTokens.card)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }
}
