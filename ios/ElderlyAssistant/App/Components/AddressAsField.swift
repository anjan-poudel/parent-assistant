import SwiftUI

// MARK: - Address-as input (profile-interview, T-098 / C03)
//
// The ONE address-as input, shared by the About-you wizard step and the
// Settings editor. Preset chips for the active language plus a free-text
// field; writes clamp to `bounds.addressAsMaxGraphemes` on Character
// boundaries. A chip's term IS the stored term — the presets are data
// constants (ADR-05 / FR-PI-010), never localised display strings, so the
// assistant addresses the user with exactly the word the elder chose.

/// Chip options per language code. Data, not catalog strings: a chip's
/// term IS the stored term (ADR-05 / FR-PI-010), never a localised
/// display string. Unknown languages fall back to the en set.
enum AddressAsPresets {
    static func terms(for languageCode: String) -> [String] {
        switch languageCode {
        case "ne":
            return ["आमा", "ममी", "बुबा", "दाइ", "दिदी",
                    "बजै", "हजुरबुबा", "हजुरआमा"]
        default:
            return ["Mum", "Mom", "Dad", "Grandma", "Grandpa"]
        }
    }
}

/// Shared address-as input. `locale` drives which preset set renders; the
/// free-text field's writes pass through `ProfileText.clamped` so an
/// over-long entry never splits a grapheme cluster (R10 — Devanagari
/// conjuncts are single Characters).
struct AddressAsField: View {
    @Binding var text: String
    let locale: Locale
    var bounds: ProfileEntryBounds = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Horizontal scroll, not a wrapping grid: two to eight chips
            // per language, and the elder scrolls with the same gesture
            // the rest of the app teaches.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(AddressAsPresets.terms(for: languageCode),
                            id: \.self) { term in
                        chip(term)
                    }
                }
                .padding(.vertical, 2)
            }
            TextField("profile.field.addressAs", text: clampedText)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundStyle(DesignTokens.textPrimary)
                .padding(.horizontal, 16)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .background(DesignTokens.card)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .accessibilityLabel(Text("profile.field.addressAs"))
        }
    }

    private var languageCode: String {
        locale.language.languageCode?.identifier ?? locale.identifier
    }

    /// The grapheme-safe binding: SwiftUI writes through the setter, so
    /// the value stored in the draft can never exceed the bound or split
    /// a cluster.
    private var clampedText: Binding<String> {
        Binding(
            get: { text },
            set: { text = ProfileText.clamped($0,
                                             maxGraphemes: bounds.addressAsMaxGraphemes) }
        )
    }

    /// A chip's term is written as data, verbatim. The label the user
    /// reads IS the term, and the accessibility label is the same term —
    /// no localisation layer sits between (ADR-05).
    private func chip(_ term: String) -> some View {
        Button {
            text = term
        } label: {
            Text(term)
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .medium))
                .foregroundStyle(DesignTokens.textPrimary)
                .padding(.horizontal, 18)
                .frame(minWidth: DesignTokens.minTapTargetSize,
                       minHeight: DesignTokens.minTapTargetSize)
                .background(DesignTokens.card)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(DesignTokens.accent.opacity(0.35),
                                          lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(term))
    }
}
