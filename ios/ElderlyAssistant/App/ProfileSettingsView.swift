import SwiftUI

// MARK: - Settings: About me (profile-interview, T-103 / C08)
//
// The Settings-side editor for the same record the interview wizard
// collects: name, address-as, optional DOB, GP and hospital. One Save
// button writes the complete record through the coordinator's single
// writer; success and failure both surface inline. The next-of-kin
// designation is NOT edited here — it rides on the Family screen's
// emergency flag (see the note under the fields).

struct ProfileSettingsView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @StateObject private var model: ProfileSettingsModel

    init(coordinator: AppCoordinator) {
        _model = StateObject(wrappedValue: ProfileSettingsModel(coordinator: coordinator))
    }

    var body: some View {
        LeafScreen(titleKey: "settings.profile.title") {
            VStack(alignment: .leading, spacing: 16) {
                Text("settings.profile.explanation")
                    .font(.system(size: DesignTokens.minBodyPointSize))
                    .foregroundStyle(DesignTokens.textSecondary)

                nameField
                addressAsSection
                dateOfBirthSection
                emergencySection

                Text("profile.kin.note")
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundStyle(DesignTokens.textSecondary)

                saveArea
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .onAppear { model.load() }
    }

    // MARK: fields

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("profile.field.name")
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                .foregroundStyle(DesignTokens.textSecondary)
            TextField("profile.field.name", text: clampedName)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundStyle(DesignTokens.textPrimary)
                .padding(.horizontal, 16)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .background(DesignTokens.card)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .accessibilityLabel(Text("profile.field.name"))
        }
    }

    private var addressAsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("profile.field.addressAs")
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                .foregroundStyle(DesignTokens.textSecondary)
            AddressAsField(text: $model.addressAs,
                           locale: coordinator.activeLocale,
                           bounds: model.bounds)
        }
    }

    private var dateOfBirthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("profile.field.dateOfBirth", isOn: $model.hasDateOfBirth)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .foregroundStyle(DesignTokens.textPrimary)
                // iOS 16 single-parameter onChange (the two-parameter
                // closure overload is iOS 17-only; deployment target is
                // 16.0 — same form as the rest of the codebase).
                .onChange(of: model.hasDateOfBirth) { isOn in
                    // Seed the wheel so an untouched picker still records
                    // a date; the merge stores components only.
                    if isOn, model.dateOfBirth == nil {
                        model.dateOfBirth = Self.defaultBirthDate
                    }
                }
            if model.hasDateOfBirth {
                DatePicker("",
                           selection: birthDateBinding,
                           displayedComponents: [.date])
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(Text("profile.field.dateOfBirth"))
            }
        }
    }

    private var emergencySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("profile.field.doctor")
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                .foregroundStyle(DesignTokens.textSecondary)
            TextField("profile.field.doctor", text: $model.emergencyDoctor)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .padding(.horizontal, 16)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .background(DesignTokens.card)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            TextField("profile.field.hospital", text: $model.localHospital)
                .font(.system(size: DesignTokens.minBodyPointSize))
                .padding(.horizontal, 16)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .background(DesignTokens.card)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: save

    @ViewBuilder
    private var saveArea: some View {
        Button {
            model.save()
        } label: {
            Text("profile.save")
                .font(.system(size: DesignTokens.minBodyPointSize, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: DesignTokens.minTapTargetSize)
                .background(DesignTokens.accent)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.bubbleCornerRadius))
        }
        .buttonStyle(.plain)

        switch model.saveState {
        case .idle:
            EmptyView()
        case .saved:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: DesignTokens.minCaptionPointSize))
                    .foregroundStyle(DesignTokens.accent)
                Text("profile.saved")
                    .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                    .foregroundStyle(DesignTokens.accent)
            }
        case .failed:
            Text("profile.error.saveFailed")
                .font(.system(size: DesignTokens.minCaptionPointSize, weight: .semibold))
                .foregroundStyle(DesignTokens.stateError)
        }
    }

    // MARK: bindings

    /// The grapheme-safe name binding (60 Characters) — same clamp helper
    /// as the wizard step, so Devanagari conjuncts never split.
    private var clampedName: Binding<String> {
        Binding(
            get: { model.name },
            set: { model.name = ProfileText.clamped($0,
                                                    maxGraphemes: model.bounds.nameMaxGraphemes) }
        )
    }

    private var birthDateBinding: Binding<Date> {
        Binding(get: { model.dateOfBirth ?? Self.defaultBirthDate },
                set: { model.dateOfBirth = $0 })
    }

    private static let defaultBirthDate: Date = Calendar.current.date(
        from: DateComponents(year: 1950, month: 1, day: 1)) ?? Date()
}
