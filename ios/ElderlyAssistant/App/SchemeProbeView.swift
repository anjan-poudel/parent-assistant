import SwiftUI

// MARK: - URL scheme tester (diagnostic tool, 2026-09-19)

/// A tiny in-app laboratory for URL schemes: type a scheme, PROBE asks
/// `canOpenURL` (the honest availability answer), OPEN tries to launch
/// it. Lives in the hidden Settings sheet — it is a developer tool, not
/// an elder surface.
///
/// Honesty rules the results: an un-whitelisted scheme probes as false
/// REGARDLESS of whether an app registers it (`LSApplicationQueries
/// Schemes` gating since iOS 9) — so the candidate chips below are
/// whitelisted in Info.plist, and a custom scheme the tester types gets
/// the "not whitelisted — the answer cannot be trusted" caveat instead
/// of a confident lie.
struct SchemeProbeView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var schemeText = "contact://"
    @State private var probeResult: ProbeOutcome?
    @State private var openResult: OpenOutcome?

    /// The candidate schemes, pinned as a static list so a test can hold
    /// the order (and so the whitelist and the chips can be diffed).
    static let candidateSchemes: [String] = [
        "contact://", "people://",
        "mobilephone://", "mobilephone-contacts://",
        "mobilephone-favorites://", "mobilephone-recents://",
        "mobilephone-voicemail://", "vmshow://",
        "tel:", "telprompt://",
        "whatsapp://", "fb-messenger://",
        "calshow://", "prefs:root=Phone",
    ]

    private enum ProbeOutcome {
        case registered
        case notRegistered
        case notWhitelisted
    }

    private enum OpenOutcome {
        case opened
        case failed
    }

    private var normalizedScheme: String {
        schemeText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isWhitelisted: Bool {
        // The probe is only honest for schemes the app declares. Keep
        // this in sync with Info.plist's LSApplicationQueriesSchemes.
        let whitelisted: Set<String> = [
            "contact", "people", "mobilephone", "mobilephone-contacts",
            "mobilephone-favorites", "mobilephone-recents",
            "mobilephone-voicemail", "vmshow", "tel", "telprompt",
            "whatsapp", "fb-messenger", "calshow", "prefs",
        ]
        return whitelisted.contains(Self.bareScheme(of: normalizedScheme))
    }

    /// The scheme part of a URL string — everything before the first
    /// `:` (so `prefs:root=Phone` reads as `prefs`, `tel:` as `tel`,
    /// `contact://` as `contact`). This is what the whitelist declares;
    /// the path is irrelevant to it.
    static func bareScheme(of text: String) -> String {
        let withoutSlashes = text.replacingOccurrences(of: "//", with: "")
        return withoutSlashes.components(separatedBy: ":").first ?? withoutSlashes
    }

    var body: some View {
        LeafScreen(titleKey: "settings.schemeProbe.title") {
            VStack(spacing: 14) {
                TextField("contact://", text: $schemeText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .padding(14)
                    .frame(minHeight: 56)
                    .background(DesignTokens.card)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))

                HStack(spacing: 12) {
                    Button {
                        probeResult = nil
                        openResult = nil
                        guard let url = URL(string: normalizedScheme) else { return }
                        guard isWhitelisted else {
                            probeResult = .notWhitelisted
                            return
                        }
                        probeResult = UIApplication.shared.canOpenURL(url)
                            ? .registered : .notRegistered
                    } label: {
                        Text(LocalizedStringKey("settings.schemeProbe.probe"))
                            .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .frame(minHeight: DesignTokens.minTapTargetSize)
                            .background(DesignTokens.accent)
                            .clipShape(Capsule())
                    }

                    Button {
                        probeResult = nil
                        openResult = nil
                        guard let url = URL(string: normalizedScheme) else { return }
                        UIApplication.shared.open(url) { ok in
                            openResult = ok ? .opened : .failed
                        }
                    } label: {
                        Text(LocalizedStringKey("settings.schemeProbe.open"))
                            .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                            .foregroundStyle(DesignTokens.textPrimary)
                            .padding(.horizontal, 18)
                            .frame(minHeight: DesignTokens.minTapTargetSize)
                            .background(DesignTokens.background)
                            .clipShape(Capsule())
                    }
                }

                outcomeRow

                Text("settings.schemeProbe.chipsHeader")
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                    .foregroundStyle(DesignTokens.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)

                FlowChips(items: Self.candidateSchemes) { scheme in
                    schemeText = scheme
                    probeResult = nil
                    openResult = nil
                }

                Text("settings.schemeProbe.whitelistNote")
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundStyle(DesignTokens.textSecondary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var outcomeRow: some View {
        if let probeResult {
            Text(probeKey(probeResult))
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                .foregroundStyle(probeResult == .registered
                                 ? DesignTokens.stateSpeaking : DesignTokens.stateError)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let openResult {
            Text(openResult == .opened
                 ? L10n.str("settings.schemeProbe.opened", locale: coordinator.activeLocale)
                 : L10n.str("settings.schemeProbe.openFailed", locale: coordinator.activeLocale))
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .semibold))
                .foregroundStyle(openResult == .opened
                                 ? DesignTokens.stateSpeaking : DesignTokens.stateError)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func probeKey(_ outcome: ProbeOutcome) -> String {
        switch outcome {
        case .registered: return L10n.str("settings.schemeProbe.registered", locale: coordinator.activeLocale)
        case .notRegistered: return L10n.str("settings.schemeProbe.notRegistered", locale: coordinator.activeLocale)
        case .notWhitelisted: return L10n.str("settings.schemeProbe.notWhitelisted", locale: coordinator.activeLocale)
        }
    }
}

/// The chip cloud the tester's candidates render as — wrap-based, each
/// chip sets the scheme field. Deliberately a tiny local component, not a
/// general-purpose chip system (the one-shot need does not earn one).
private struct FlowChips: View {
    let items: [String]
    let onPick: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)],
                  alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                Button {
                    onPick(item)
                } label: {
                    Text(item)
                        .font(.system(size: DesignTokens.minCaptionPointSize))
                        .foregroundStyle(DesignTokens.textPrimary)
                        .padding(.horizontal, 10)
                        .frame(minHeight: DesignTokens.minTapTargetSize)
                        .background(DesignTokens.card)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
