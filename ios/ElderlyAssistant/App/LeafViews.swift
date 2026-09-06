import SwiftUI
import UIKit
import AVFoundation
import Speech

/// Shared leaf-screen chrome: huge back button, single-purpose layout
/// (spec §4.3). Every hub leaf uses this.
///
/// Redesign spec §3.2: this is a PLAIN full-screen page — no Talk hero, no
/// hint carousel, no dock. The one exception is the Emergency icon, which
/// persists on every screen because it's a safety invariant, not
/// conversational voice chrome.
struct LeafScreen<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let titleKey: String
    let content: Content

    init(titleKey: String, @ViewBuilder content: () -> Content) {
        self.titleKey = titleKey
        self.content = content()
    }

    var body: some View {
        ZStack {
            DesignTokens.background.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundColor(DesignTokens.textPrimary)
                            .frame(width: DesignTokens.minTapTargetSize,
                                   height: DesignTokens.minTapTargetSize)
                            .background(DesignTokens.card)
                            .clipShape(Circle())
                    }
                    .accessibilityLabel(Text("common.back"))
                    Text(LocalizedStringKey(titleKey))
                        .font(DesignTokens.greetingFont(size: DesignTokens.titlePointSize))
                        .foregroundColor(DesignTokens.textPrimary)
                    Spacer()
                    EmergencyIconButton()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)

                ScrollView {
                    content
                        .padding(.horizontal, 20)
                        .padding(.bottom, 32)
                }
            }
        }
        .navigationBarHidden(true)
    }
}

// MARK: - Meds (औषधि) — spec §4.3

/// Today's dose list with a big "लिएँ" button per pending dose. Taking a
/// dose issues the confirmation challenge (FR-D01/FR-D03) and returns to
/// Home, where the yes/no chips appear.
struct MedsView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var session: VoiceSessionStateMachine
    @Environment(\.dismiss) private var dismiss

    private var todaysReminders: [ScheduledReminder] {
        coordinator.pendingReminders
            .filter { Calendar.current.isDateInToday($0.scheduledAt) }
            .sorted { $0.scheduledAt < $1.scheduledAt }
    }

    var body: some View {
        LeafScreen(titleKey: "meds.title") {
            if todaysReminders.isEmpty {
                emptyState(key: "meds.empty")
            } else {
                VStack(spacing: 12) {
                    ForEach(todaysReminders) { reminder in
                        doseRow(reminder)
                    }
                }
            }
        }
    }

    private func doseRow(_ reminder: ScheduledReminder) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(coordinator.medicationName(for: reminder.medicationEntryId))
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(DesignTokens.textPrimary)
                Text(reminder.scheduledAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
            }
            Spacer()
            Button {
                takeDose(reminder)
            } label: {
                Text("meds.iTookIt")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .frame(height: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.accent)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }

    /// Baseline ack or challenge → Home for the yes/no chips. The
    /// confirmation answer is handled by the chips/voice on Home.
    private func takeDose(_ reminder: ScheduledReminder) {
        let entryId = reminder.medicationEntryId
        if coordinator.startVoiceAckConfirmation(for: entryId) != nil {
            // Challenge issued — chips now own the UI on Home.
            dismiss()
        } else {
            coordinator.handleMedicationAcknowledgement(entryId: entryId)
            coordinator.speak(key: "router.confirmationYes")
        }
    }
}

// MARK: - Reminders (सम्झना) — spec §4.3 + v2 pivot Phase 1

/// Today's reminders from BOTH reminder systems — medication doses
/// (`MedicationScheduler`) and routine occurrences (walk, exercise,
/// meals, … from `RoutineScheduler`) — plus a manage list where the
/// family enables/disables the seeded routine categories. Medication
/// management stays on the Meds leaf / Settings editor; this screen
/// never mutates medication data.
struct RemindersView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    /// Bumped after a toggle so the computed lists re-read fresh data —
    /// the coordinator exposes reminders as computed vars, not @Published.
    @State private var entriesVersion = 0

    /// One row per today's reminder, both systems, sorted by time.
    private var todayRows: [TodayRow] {
        _ = entriesVersion
        // One store read for the whole list, not two per row.
        let entriesById = Dictionary(
            uniqueKeysWithValues: coordinator.routineEntries.map { ($0.id, $0) }
        )
        let meds = coordinator.pendingReminders
            .filter { Calendar.current.isDateInToday($0.scheduledAt) }
            .map { TodayRow(id: $0.id, scheduledAt: $0.scheduledAt,
                            title: coordinator.medicationName(for: $0.medicationEntryId),
                            systemImage: RoutineCategory.medication.systemImage,
                            isDimmed: false) }
        let routines = coordinator.todaysRoutineOccurrences.map { occurrence in
            let entry = entriesById[occurrence.entryId]
            return TodayRow(id: occurrence.id, scheduledAt: occurrence.scheduledAt,
                            title: entry?.displayTitle(locale: coordinator.activeLocale)
                                ?? L10n.str("routine.category.custom", locale: coordinator.activeLocale),
                            systemImage: entry?.category.systemImage
                                ?? RoutineCategory.custom.systemImage,
                            isDimmed: occurrence.state != .pending)
        }
        return (meds + routines).sorted { $0.scheduledAt < $1.scheduledAt }
    }

    var body: some View {
        LeafScreen(titleKey: "reminders.title") {
            VStack(spacing: 12) {
                if todayRows.isEmpty {
                    emptyState(key: "reminders.empty")
                } else {
                    sectionHeader(key: "reminders.todaySection")
                    ForEach(todayRows) { row in
                        todayRowView(row)
                    }
                }

                if !coordinator.routineEntries.isEmpty {
                    sectionHeader(key: "reminders.routinesSection")
                    ForEach(coordinator.routineEntries) { entry in
                        routineManageRow(entry)
                    }
                }
            }
        }
    }

    private struct TodayRow: Identifiable {
        let id: UUID
        let scheduledAt: Date
        let title: String
        let systemImage: String
        /// Past/expired occurrences stay visible but de-emphasised — the
        /// elder still sees "walk was at 5:30" as context for the day.
        let isDimmed: Bool
    }

    private func sectionHeader(key: String) -> some View {
        Text(LocalizedStringKey(key))
            .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
            .foregroundColor(DesignTokens.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }

    private func todayRowView(_ row: TodayRow) -> some View {
        HStack(spacing: 12) {
            Image(systemName: row.systemImage)
                .font(.system(size: 24))
                .foregroundColor(row.isDimmed ? DesignTokens.textSecondary : DesignTokens.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title)
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(row.isDimmed ? DesignTokens.textSecondary : DesignTokens.textPrimary)
                Text(row.scheduledAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    private func routineManageRow(_ entry: RoutineEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.category.systemImage)
                .font(.system(size: 24))
                .foregroundColor(DesignTokens.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.displayTitle(locale: coordinator.activeLocale))
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(DesignTokens.textPrimary)
                Text(scheduleSummary(entry))
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { entry.isEnabled },
                set: { enabled in
                    coordinator.setRoutineEntryEnabled(entry.id, enabled: enabled)
                    entriesVersion += 1
                }
            ))
            .labelsHidden()
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    /// "7:00 AM, 4:00 PM" for daily entries; weekly entries prefix the
    /// localized weekday names ("Sun, Tue · 9:00 AM").
    private func scheduleSummary(_ entry: RoutineEntry) -> String {
        let calendar = Calendar.current
        let times = entry.scheduleTimes.compactMap { components -> String? in
            calendar.date(from: components)?.formatted(date: .omitted, time: .shortened)
        }
        let timesText = times.joined(separator: ", ")
        guard entry.frequency == .weekly, !entry.weekdays.isEmpty else { return timesText }
        let formatter = DateFormatter()
        formatter.locale = coordinator.activeLocale
        guard let symbols = formatter.shortWeekdaySymbols else { return timesText }
        let days = entry.weekdays.sorted().compactMap { weekday -> String? in
            weekday >= 1 && weekday <= symbols.count ? symbols[weekday - 1] : nil
        }
        return days.joined(separator: ", ") + " · " + timesText
    }
}

// MARK: - Call (फोन) — redesign spec §3.2 + system-contacts search (2026-09-06)

/// Replaces the old fail-closed placeholder. `CommandRouter`'s `.call`
/// handling (voice-triggered "call X") stays blocked, unchanged, pending
/// voice-biometric auth — that's a `CommandRouter`/pipeline concern this
/// redesign does not touch. TAPPING a contact here is a different trust
/// model: it's the user's own hand on their own unlocked phone, the same
/// as any contacts app, so it places a real call directly.
///
/// System-contacts search (2026-09-06, task: "sweep all sweepable
/// contacts when searching, sort by most recently used"): the leaf now
/// also searches the SYSTEM address book — which on iOS is the sweep.
/// The system Contacts app already aggregates the user's own entries AND
/// people synced in by third-party apps (WhatsApp, Messenger, …) as
/// plain contacts, so one `CNContactStore` pass reaches every dialable
/// person without any per-app SDK. Matches rank with numbers this app
/// recently called first (`CallRecencyStore`), then alphabetically.
/// Contacts permission is asked at the point of use behind a
/// plain-language card — never silently on appear — and the family
/// tiles below stay fully usable with or without it.
struct CallView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.scenePhase) private var scenePhase

    private let directory = AddressBookDirectory()

    @State private var searchText = ""
    /// nil while the authorization state is still being read.
    @State private var access: ContactsAccess?
    /// nil = not loaded yet (or load in flight).
    @State private var entries: [AddressBookEntry]?
    @State private var loadFailed = false
    /// Normalized number → last call date; refreshed on appear and after
    /// each dial so the "recently used" ranking stays current.
    @State private var recency: [String: Date] = [:]

    // Voice search (voice-contact-search, 2026-09-07).
    /// One-shot mic-capture phase for the search field's mic button.
    private enum MicPhase { case idle, listening, failed }
    @State private var micPhase: MicPhase = .idle
    /// True once speech/mic permission is denied — the button is honest
    /// dead for this visit (the denial might be reversible in Settings;
    /// next visit re-checks).
    @State private var micHidden = false
    /// The voice-command search this leaf is currently answering
    /// (nil when none): the request id plus the query to announce.
    @State private var voiceRequest: AppCoordinator.ContactSearchRequest?
    /// Guards the spoken announcement to ONCE per request: set when the
    /// result was announced (or the ask became moot — user edited away).
    @State private var announcedVoiceSearchID: UUID?

    // Messenger username capture (deep-link fix, 2026-09-07): Messenger
    // has no phone-number thread link, so a row without a handle asks
    // once for the person's username, stores it, and opens the thread.
    @State private var showHandlePrompt = false
    @State private var handleText = ""
    @State private var pendingHandleResult: UnifiedContactSearch.Result?

    var body: some View {
        LeafScreen(titleKey: "call.title") {
            VStack(spacing: 12) {
                historyRow
                searchArea
                if isSearching {
                    resultsArea
                } else {
                    familyArea
                }
            }
        }
        .onAppear {
            refreshDirectory()
            // A voice command may have pushed this leaf — consume the
            // request and prefill; a fresh publish while the leaf was
            // already open is picked up by the onChange below.
            consumePendingVoiceRequestIfPresent()
        }
        .onChange(of: coordinator.pendingContactSearchRequest?.id) { _ in
            consumePendingVoiceRequestIfPresent()
        }
        .onChange(of: entries) { _ in
            announceVoiceResultIfReady()
        }
        .onChange(of: loadFailed) { _ in
            announceVoiceResultIfReady()
        }
        .onChange(of: searchText) { _ in
            // A change the USER made (typing, clearing) retires the voice
            // ask: the elder is refining by hand, so the results were
            // theirs to see — never speak over them late. Our own prefill
            // sets searchText == voiceRequest.query, which is not a
            // retirement (trimmedQuery matches, so nothing happens here).
            if let voice = voiceRequest, trimmedQuery != voice.query {
                announcedVoiceSearchID = voice.id
            }
        }
        .onChange(of: scenePhase) { phase in
            // Returning from Settings after the access card's
            // "Open Settings" is the denial → grant path; re-check then.
            if phase == .active {
                refreshDirectory()
                // Permission state may have changed in Settings too.
                updateMicVisibility()
            }
        }
        .onDisappear {
            // Never leave the voice suspended and the mic open: a leaf
            // the user walked away from must not keep listening. The
            // capture completion (fires on cancel) restarts the pipeline.
            if micPhase == .listening {
                coordinator.cancelSearchPhraseCapture()
            }
            micPhase = .idle
        }
        .alert(L10n.fmt("messenger.handlePrompt.title",
                        locale: coordinator.appLanguage.locale,
                        pendingHandleResult?.name ?? ""),
               isPresented: $showHandlePrompt) {
            TextField(L10n.str("messenger.handlePrompt.placeholder",
                               locale: coordinator.appLanguage.locale),
                      text: $handleText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(L10n.str("messenger.handlePrompt.save",
                            locale: coordinator.appLanguage.locale)) {
                saveCapturedHandle()
            }
            Button(L10n.str("messenger.handlePrompt.cancel",
                            locale: coordinator.appLanguage.locale),
                   role: .cancel) {
                pendingHandleResult = nil
            }
        } message: {
            Text(L10n.str("messenger.handlePrompt.body",
                          locale: coordinator.appLanguage.locale))
        }
    }

    /// Entry point to the Recent activity leaf (call-history task,
    /// 2026-09-06) — the assistant's OWN calls and messages, so it is
    /// reachable with or without contacts permission (history needs
    /// none) and lives one row above the search that does.
    private var historyRow: some View {
        NavigationLink(value: LeafDestination.history) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DesignTokens.accent)
                Text(LocalizedStringKey("call.historyRow"))
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: DesignTokens.minTapTargetSize)
            .background(DesignTokens.card)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var isSearching: Bool { !trimmedQuery.isEmpty }

    /// Big search pill (≥44pt, body-size text, warm card). Search runs as
    /// the user types — no submit step to fumble.
    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(DesignTokens.textSecondary)
            TextField("call.search.placeholder", text: $searchText)
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

    /// In-pill voice-search button (voice-contact-search, 2026-09-07):
    /// one shot captures a name into the search field — refinement when
    /// the elder is already here. ≥44pt tap target (DesignTokens floor).
    /// While listening it becomes the stop control; the caption below
    /// the pill says what the mic is doing.
    private var micButton: some View {
        let listening = micPhase == .listening
        return Button(action: micTapped) {
            Image(systemName: listening ? "stop.fill" : "mic.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(listening ? .white : DesignTokens.accent)
                .frame(width: 30, height: 30)
                .background(listening ? DesignTokens.accent : DesignTokens.background)
                .clipShape(Circle())
        }
        .frame(minWidth: DesignTokens.minTapTargetSize,
               minHeight: DesignTokens.minTapTargetSize)
        .accessibilityLabel(Text(LocalizedStringKey(
            listening ? "call.search.micStopLabel" : "call.search.micLabel")))
    }

    /// What the mic is doing right now — a caption under the pill while
    /// listening ("say the name") or after a failed attempt ("the mic
    /// couldn't hear — try again"). Silent otherwise.
    @ViewBuilder
    private var micCaption: some View {
        switch micPhase {
        case .listening:
            Text(L10n.str("call.search.micListening", locale: coordinator.activeLocale))
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundColor(DesignTokens.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
        case .failed:
            Text(L10n.str("call.search.micFailed", locale: coordinator.activeLocale))
                .font(.system(size: DesignTokens.minCaptionPointSize))
                .foregroundColor(DesignTokens.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
        case .idle:
            EmptyView()
        }
    }

    private var loadingCard: some View {
        AddressBookLoadingCard()
    }

    private var loadFailedCard: some View {
        AddressBookLoadFailedCard(retry: loadEntries)
    }

    // MARK: Permission / loading states

    @ViewBuilder
    private var searchArea: some View {
        if access == .allowed {
            searchField
            micCaption
            if entries == nil {
                if loadFailed {
                    loadFailedCard
                } else {
                    loadingCard
                }
            }
        } else if access == .denied {
            AddressBookAccessCard(mode: .blocked)
        } else if access == .notDetermined {
            // The one point-of-use ask — plain-language card first, the
            // system prompt only after the user taps Allow.
            AddressBookAccessCard(mode: .ask, onAllow: grantAccess)
        }
        // access == nil: authorization still being read; render nothing
        // so the ask card can never flash before onAppear resolves it.
    }

    private func refreshDirectory() {
        let status = AddressBookDirectory.access()
        access = status
        guard status == .allowed else { return }
        recency = coordinator.contactCallRecency
        if entries == nil || loadFailed {
            loadEntries()
        }
    }

    /// The user tapped Allow on the access card — the ONE place the
    /// permission prompt may fire (point of use, constitution).
    private func grantAccess() {
        Task {
            let granted = await directory.requestAccess()
            access = AddressBookDirectory.access()
            if granted {
                recency = coordinator.contactCallRecency
                loadEntries()
            }
        }
    }

    private func loadEntries() {
        loadFailed = false
        Task {
            do {
                // A full-book enumerate can take a moment on first
                // access — never block the main thread for it.
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try AddressBookDirectory().allEntries()
                }.value
                self.entries = loaded
            } catch {
                self.loadFailed = true
            }
        }
    }

    // MARK: - Voice search (voice-contact-search, 2026-09-07)

    /// True when the mic button may be shown: contacts are searchable and
    /// neither speech nor mic permission is dead. `.notDetermined` counts
    /// as visible — the ask happens at the tap (point of use); a denial
    /// flips `micHidden` for the rest of this visit.
    private var micButtonVisible: Bool {
        guard !micHidden, access == .allowed else { return false }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized, .notDetermined: break
        case .denied, .restricted: return false
        @unknown default: return false
        }
        if micRecordPermissionDenied() { return false }
        return true
    }

    private func updateMicVisibility() {
        // Denied in Settings while this view was alive → hide. Computed
        // fresh each appearance and on scenePhase → .active.
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
        // CallView is a struct — the @State mutations below are captured
        // by value through the binding, so no weak dance is needed (or
        // allowed); the closure only outlives the view briefly while the
        // one-shot capture runs.
        coordinator.startSearchPhraseCapture { result in
            switch result {
            case .success(let text):
                self.micPhase = .idle
                // As-you-type search picks the transcript up from here.
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

    /// Consumes the coordinator's pending contact-search request (set by
    /// the router keyword pre-route) and applies it: navigate is already
    /// done — HomeView pushed this leaf — so here the query pre-fills the
    /// search field and the results (incl. WhatsApp/Messenger badges)
    /// land on screen, zero-touch. A nil query means "open the screen
    /// unprefilled" — nothing to announce.
    private func consumePendingVoiceRequestIfPresent() {
        guard let request = coordinator.takePendingContactSearchRequest() else { return }
        micPhase = .idle
        guard let query = request.query else {
            voiceRequest = nil
            return
        }
        voiceRequest = AppCoordinator.ContactSearchRequest(query: query)
        searchText = query
        // Entries may still be loading (onChange(of: entries) will call
        // back), but when they are here the results are on screen NOW.
        announceVoiceResultIfReady()
    }

    /// Speaks the outcome of a voice-commanded search — once per request
    /// — so the elder hears "मैया फेला पर्‍यो — कल गर्न थिच्नुहोस्"
    /// without looking. Silence unless every condition holds: a real
    /// voice query is pending, results are actually rendered (contacts
    /// allowed, book loaded, no load failure), and the field still holds
    /// the voice query (an edit retires the ask — handled in the
    /// searchText onChange). Runs as the coordinator's TTS — the same
    /// channel the assistant always speaks on.
    private func announceVoiceResultIfReady() {
        guard let voice = voiceRequest,
              announcedVoiceSearchID != voice.id,
              access == .allowed,
              let entries,
              !loadFailed,
              trimmedQuery == voice.query else { return }
        announcedVoiceSearchID = voice.id
        let outcome = UnifiedContactSearch.search(query: trimmedQuery,
                                                  family: coordinator.familyContacts,
                                                  in: entries,
                                                  recency: recency)
        let locale = coordinator.activeLocale
        if let name = outcome.entries.first?.name {
            coordinator.speak(text: L10n.fmt("call.search.spokenFound", locale: locale, name))
        } else {
            coordinator.speak(text: L10n.fmt("call.search.spokenNotFound", locale: locale, trimmedQuery))
        }
    }

    private func dial(_ result: UnifiedContactSearch.Result) {
        coordinator.performSystemContactCall(name: result.name, phone: result.phone)
        // Keep THIS list's ranking current without waiting for the next
        // view appearance; the coordinator store stays the source of
        // truth.
        recency[ContactNumberKey.normalized(result.phone)] = Date()
    }

    /// The row's WhatsApp pill — a chat surface, not a call, so no
    /// recency entry (channel opens are not dials).
    private func whatsApp(_ result: UnifiedContactSearch.Result) {
        coordinator.performSystemContactWhatsApp(name: result.name, phone: result.phone)
    }

    /// The row's Messenger pill. Resolution order (2026-09-07):
    /// address-book-derived handle → family-captured stored handle
    /// (`MessengerHandleStore`, keyed by normalized phone) → capture
    /// prompt. Messenger has NO phone-number thread link, so a row
    /// without a handle prompts once for the username; from then on
    /// the pill opens the person's real thread, where the audio/video
    /// buttons sit.
    private func messenger(_ result: UnifiedContactSearch.Result) {
        let normalized = ContactNumberKey.normalized(result.phone)
        let stored = normalized.isEmpty
            ? nil
            : coordinator.storedMessengerHandle(forNormalizedPhone: normalized)
        if let handle = result.messengerHandle ?? stored, !handle.isEmpty {
            coordinator.performSystemContactMessenger(name: result.name, handle: handle)
        } else if normalized.isEmpty {
            // Defensive: no phone and no handle means nothing can ever
            // be linked — the honest no-handle line, never a dead tap.
            coordinator.performSystemContactMessenger(name: result.name, handle: "")
        } else {
            pendingHandleResult = result
            handleText = ""
            showHandlePrompt = true
        }
    }

    /// Save action of the username-capture prompt: normalize, persist,
    /// and open the thread — or, for an unusable entry, speak the
    /// honest no-handle line (the user can re-tap and try again).
    private func saveCapturedHandle() {
        guard let result = pendingHandleResult else { return }
        let normalized = ContactNumberKey.normalized(result.phone)
        let handle = CallLinks.messengerHandle(handleText)
        if !handle.isEmpty, !normalized.isEmpty {
            coordinator.storeMessengerHandle(handle, forNormalizedPhone: normalized)
            coordinator.performSystemContactMessenger(name: result.name, handle: handle)
        } else {
            coordinator.performSystemContactMessenger(name: result.name, handle: "")
        }
        pendingHandleResult = nil
    }

    // MARK: Result / family areas

    @ViewBuilder
    private var resultsArea: some View {
        if let entries {
            let outcome = UnifiedContactSearch.search(query: trimmedQuery,
                                                      family: coordinator.familyContacts,
                                                      in: entries,
                                                      recency: recency)
            if outcome.moreAvailable {
                Text("call.search.moreAvailable")
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            if outcome.entries.isEmpty {
                // An empty book AND no family at all, vs. a query that
                // simply matched nobody, are different truths — say
                // which one it is.
                if entries.isEmpty && coordinator.familyContacts.isEmpty {
                    emptyState(key: "call.search.bookEmpty")
                } else {
                    emptyState(key: "call.search.noResults")
                }
            } else {
                VStack(spacing: 12) {
                    ForEach(outcome.entries) { result in
                        UnifiedContactResultRow(result: result,
                                                dial: { dial(result) },
                                                whatsApp: { whatsApp(result) },
                                                messenger: { messenger(result) })
                    }
                }
            }
        }
    }

    /// The in-app family tiles (spec §4.4) — always reachable, with or
    /// without contacts permission or a search query.
    @ViewBuilder
    private var familyArea: some View {
        if coordinator.familyContacts.isEmpty {
            emptyState(key: "call.contactsEmpty")
        } else {
            VStack(spacing: 12) {
                ForEach(coordinator.familyContacts) { contact in
                    ContactTile(contact: contact)
                }
            }
        }
    }
}

/// Permission state card for the contacts search. `.ask` appears while
/// the app may still request access and explains WHY in plain language
/// before the prompt fires (constitution: request at the point of use);
/// `.blocked` appears after a denial or restriction, whose only forward
/// path is the system Settings screen. Either way the family tiles stay
/// visible beneath it — nothing is held hostage to the permission.
private enum AddressBookAccessMode {
    case ask
    case blocked
}

private struct AddressBookAccessCard: View {
    let mode: AddressBookAccessMode
    /// Fires the one-time permission request; used only by `.ask`.
    var onAllow: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Text(titleKey)
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundColor(DesignTokens.textPrimary)
                .multilineTextAlignment(.center)
            Text(bodyKey)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.textSecondary)
                .multilineTextAlignment(.center)
            Button(action: action) {
                Text(buttonKey)
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .frame(height: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.accent)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    private var titleKey: LocalizedStringKey {
        mode == .ask ? "call.search.allowTitle" : "call.search.deniedTitle"
    }
    private var bodyKey: LocalizedStringKey {
        mode == .ask ? "call.search.allowBody" : "call.search.deniedBody"
    }
    private var buttonKey: LocalizedStringKey {
        mode == .ask ? "call.search.allowButton" : "call.search.openSettings"
    }

    private func action() {
        if mode == .ask {
            onAllow?()
        } else {
            // Denied/restricted: only the system can lift it.
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        }
    }
}

private struct AddressBookLoadingCard: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("call.search.loading")
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }
}

private struct AddressBookLoadFailedCard: View {
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("call.search.loadFailed")
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundColor(DesignTokens.textSecondary)
                .multilineTextAlignment(.center)
            Button(action: retry) {
                Text("call.search.retry")
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .frame(height: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.accent)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }
}

/// One unified search result — a family member or a system address-book
/// row (family rows wear a small accent "Family" chip so the two read
/// differently). The WHOLE dial zone — avatar, name/caption, phone
/// circle — is a single button: a target comfortably larger than 44pt
/// for elderly hands, the phone circle mirroring the ContactTile audio
/// affordance as a visual cue. VoiceOver reads it as one "Call <name>"
/// button whose value is the caption. Below the dial zone, one pill per
/// chat app the person is actually reachable on opens that app's thread
/// instead of the dialer (channel availability decided by the search,
/// not guessed here).
private struct UnifiedContactResultRow: View {
    let result: UnifiedContactSearch.Result
    let dial: () -> Void
    let whatsApp: () -> Void
    let messenger: () -> Void
    @Environment(\.locale) private var locale

    /// Channel brand colors — kept here, not in DesignTokens: they are
    /// the apps' own identities, not Warm & Soft palette tokens.
    private static let whatsAppGreen = Color(red: 0.145, green: 0.827, blue: 0.4)
    private static let messengerBlue = Color(red: 0.0, green: 0.518, blue: 1.0)

    /// Whether this result is one of the app's own family contacts
    /// (vs. a system address-book row).
    private var isFamily: Bool {
        if case .family = result { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 10) {
            dialZone
            if result.whatsAppAvailable || result.messengerAvailable {
                channelPills
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }

    /// The wide dial button — tapping anywhere on the face/number zone
    /// places the GSM call.
    private var dialZone: some View {
        Button(action: dial) {
            HStack(spacing: 14) {
                FaceAvatar(name: result.name, diameter: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.name)
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                        .foregroundColor(DesignTokens.textPrimary)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        if isFamily {
                            familyChip
                        }
                        Text(result.caption)
                            .font(.system(size: DesignTokens.minCaptionPointSize))
                            .foregroundColor(DesignTokens.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "phone.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: DesignTokens.minTapTargetSize, height: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.accent)
                    .clipShape(Circle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L10n.fmt("call.callButtonLabel", locale: locale, result.name)))
        .accessibilityValue(Text(result.caption))
    }

    /// Small accent-tinted "Family" capsule prepended to the caption.
    /// Hidden from VoiceOver so the dial button stays a single read —
    /// the caption already says who this person is.
    private var familyChip: some View {
        Text(L10n.str("call.search.familyChip", locale: locale))
            .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
            .foregroundColor(DesignTokens.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(DesignTokens.accent.opacity(0.12))
            .clipShape(Capsule())
            .accessibilityHidden(true)
    }

    /// One ≥44pt capsule per reachable chat app — every surface a row
    /// offers is thumb-size, white text on the app's own brand color.
    private var channelPills: some View {
        HStack(spacing: 10) {
            if result.whatsAppAvailable {
                Button(action: whatsApp) {
                    Text(L10n.str("call.channel.whatsapp", locale: locale))
                        .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .frame(minHeight: DesignTokens.minTapTargetSize)
                        .background(Self.whatsAppGreen)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.fmt("call.channel.whatsappLabel", locale: locale, result.name)))
            }
            if result.messengerAvailable {
                Button(action: messenger) {
                    Text(L10n.str("call.channel.messenger", locale: locale))
                        .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .frame(minHeight: DesignTokens.minTapTargetSize)
                        .background(Self.messengerBlue)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.fmt("call.channel.messengerLabel", locale: locale, result.name)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Face/initial avatar + name, with per-contact VIDEO and AUDIO call
/// buttons — no list picker in between (redesign spec §3.1 "one face,
/// one tap"; contact-call-buttons task 2026-09-06). Each button opens
/// the contact's preferred app for that call kind (`FamilyContact`
/// carries the per-contact defaults; the personalization editor is a
/// deferred follow-up) through `AppCoordinator.performContactCall`,
/// which also announces the opened surface aloud.
struct ContactTile: View {
    let contact: FamilyContact
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 14) {
            FaceAvatar(name: contact.name, diameter: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name)
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                    .foregroundColor(DesignTokens.textPrimary)
                Text(contact.relationship)
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
            }
            Spacer()
            Button(action: videoCall) {
                Image(systemName: "video.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: DesignTokens.minTapTargetSize, height: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.BadgeTint.call.tint)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L10n.fmt("call.videoCallButtonLabel", locale: locale, contact.name)))
            Button(action: audioCall) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: DesignTokens.minTapTargetSize, height: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.accent)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L10n.fmt("call.callButtonLabel", locale: locale, contact.name)))
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }

    private func videoCall() {
        coordinator.performContactCall(contact, kind: .video)
    }

    private func audioCall() {
        coordinator.performContactCall(contact, kind: .audio)
    }
}

// MARK: - Calendar (पात्रो) — 2026-09-06

/// Today's date + the day's actual schedule (from the coordinator's
/// real reminder/medication data), plus today's Nepali calendar date
/// when the NepaliCalendarPlugin applies and can answer. No mock data
/// anywhere: sections that have no real content are simply omitted.
struct CalendarView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    private var todaysReminders: [ScheduledReminder] {
        coordinator.pendingReminders
            .filter { Calendar.current.isDateInToday($0.scheduledAt) }
            .sorted { $0.scheduledAt < $1.scheduledAt }
    }

    var body: some View {
        LeafScreen(titleKey: "calendar.title") {
            VStack(spacing: 12) {
                bsDateCard
                if !(coordinator.festivalCalendar.todayOverlay()?.festivals.isEmpty ?? true) {
                    festivalTodayCard
                }
                upcomingCard
                scheduleSection
            }
        }
    }

    /// The BS-first date card (2026-09-06 product direction: Nepali
    /// calendar shows Bikram Sambat dates, not Gregorian, in Nepali
    /// numerals — with the Hindu tithi overlay on every day).
    private var bsDateCard: some View {
        let overlay = coordinator.festivalCalendar.todayOverlay()
        return VStack(spacing: 8) {
            if let overlay {
                Text(overlay.weekdayNepali)
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.textSecondary)
                Text(BikramSambat.nepaliString(overlay.bsDate))
                    .font(DesignTokens.greetingFont(size: DesignTokens.titlePointSize))
                    .foregroundColor(DesignTokens.textPrimary)
                    .multilineTextAlignment(.center)
                // Tithi overlay — every day, per product requirement.
                Text(overlay.tithi.displayNepali)
                    .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                    .foregroundColor(DesignTokens.accent)
                Text(Date().formatted(.dateTime.day().month(.wide).year().locale(coordinator.activeLocale)))
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
            } else {
                Text("calendar.bsUnavailable")
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .foregroundColor(DesignTokens.textSecondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    /// Festival(s) falling today, with their tithi labels.
    private var festivalTodayCard: some View {
        let festivals = coordinator.festivalCalendar.todayOverlay()?.festivals ?? []
        return VStack(alignment: .leading, spacing: 8) {
            Text("calendar.festivalToday")
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                .foregroundColor(DesignTokens.textSecondary)
            ForEach(festivals, id: \.id) { festival in
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .foregroundColor(DesignTokens.accent)
                    Text(festival.nameNepali)
                        .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                        .foregroundColor(DesignTokens.textPrimary)
                    Spacer()
                    if let tithi = festival.tithiNepali {
                        Text(tithi)
                            .font(.system(size: DesignTokens.minCaptionPointSize))
                            .foregroundColor(DesignTokens.textSecondary)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    /// Upcoming festivals (next 5) with BS dates and days-away.
    private var upcomingCard: some View {
        let upcoming = coordinator.festivalCalendar.upcoming(limit: 5)
        return VStack(alignment: .leading, spacing: 10) {
            Text("calendar.upcomingFestivals")
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                .foregroundColor(DesignTokens.textSecondary)
            ForEach(upcoming, id: \.festival.id) { item in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.festival.nameNepali)
                            .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                            .foregroundColor(DesignTokens.textPrimary)
                        Text(BikramSambat.nepaliString(item.bsDate))
                            .font(.system(size: DesignTokens.minCaptionPointSize))
                            .foregroundColor(DesignTokens.textSecondary)
                    }
                    Spacer()
                    Text(daysAwayText(item.daysAway))
                        .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                        .foregroundColor(DesignTokens.accent)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
    }

    private func daysAwayText(_ days: Int) -> String {
        if days == 0 { return L10n.str("calendar.today", locale: coordinator.activeLocale) }
        if days == 1 { return L10n.str("calendar.tomorrow", locale: coordinator.activeLocale) }
        return L10n.fmt("calendar.inDays", locale: coordinator.activeLocale,
                        BikramSambat.devanagariDigits(days))
    }

    @ViewBuilder
    private var scheduleSection: some View {
        if !todaysReminders.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("calendar.todaySchedule")
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .bold))
                    .foregroundColor(DesignTokens.textSecondary)
                ForEach(todaysReminders) { reminder in
                    HStack(spacing: 12) {
                        IconBadge(systemImage: "clock.fill", tint: .reminders)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(coordinator.medicationName(for: reminder.medicationEntryId))
                                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                                .foregroundColor(DesignTokens.textPrimary)
                            Text(reminder.scheduledAt.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: DesignTokens.minCaptionPointSize))
                                .foregroundColor(DesignTokens.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(DesignTokens.card)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
                }
            }
        }
    }
}

// MARK: - Shared

private func emptyState(key: String) -> some View {
    Text(LocalizedStringKey(key))
        .font(.system(size: DesignTokens.minBodyPointSize))
        .foregroundColor(DesignTokens.textSecondary)
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
}
