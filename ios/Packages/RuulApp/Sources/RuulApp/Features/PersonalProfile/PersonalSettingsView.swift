import SwiftUI
import RuulCore

/// Settings.app-style sub-page for personal preferences. Foundation
/// slice (A6) ships the surface with three placeholder sections —
/// notifications, language, appearance — each wired to the real
/// system behaviour we already inherit (language = system,
/// appearance = system) plus a "Próximamente" hint for notifications
/// which lands with the push slice in Fase E.
///
/// Lives inside a NavigationStack — pushed from `PersonalProfileSheet`.
struct PersonalSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppearancePreference.storageKey) private var appearanceRaw: String = AppearancePreference.system.rawValue
    #if DEBUG
    /// R.0H.3 — debug-only opt-in para el root pivot.
    /// Default false. Si se enciende, el shell intercambia
    /// `GroupTabsHost` por `PersonalHomeView`. Apagarlo restaura
    /// la v1 de inmediato (rollback instantáneo en device).
    @AppStorage(PersonalHomeFeatureFlag.storageKey) private var personalHomeRootEnabled: Bool = false
    #endif

    private var appearanceBinding: Binding<AppearancePreference> {
        Binding(
            get: { AppearancePreference(rawValue: appearanceRaw) ?? .system },
            set: { appearanceRaw = $0.rawValue }
        )
    }

    private func appearanceLabel(_ value: AppearancePreference) -> LocalizedStringResource {
        switch value {
        case .system: return L10n.PersonalSettings.appearanceSystem
        case .light:  return L10n.PersonalSettings.appearanceLight
        case .dark:   return L10n.PersonalSettings.appearanceDark
        }
    }

    var body: some View {
        Form {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.PersonalSettings.notificationsSection)
                            .font(.body)
                        Text(L10n.PersonalSettings.notificationsHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "bell")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent {
                    Text(L10n.PersonalSettings.languageHint)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                } label: {
                    Label {
                        Text(L10n.PersonalSettings.languageSection)
                    } icon: {
                        Image(systemName: "character.book.closed")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Picker(selection: appearanceBinding) {
                    ForEach(AppearancePreference.allCases) { value in
                        Label {
                            Text(appearanceLabel(value))
                        } icon: {
                            Image(systemName: value.systemImageName)
                        }
                        .tag(value)
                    }
                } label: {
                    Label {
                        Text(L10n.PersonalSettings.appearanceSection)
                    } icon: {
                        Image(systemName: "circle.lefthalf.filled")
                            .foregroundStyle(.secondary)
                    }
                }
                .pickerStyle(.inline)
            } footer: {
                Text(L10n.PersonalSettings.appearanceHint)
            }
            #if DEBUG
            Section {
                Toggle(isOn: $personalHomeRootEnabled) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Mi mundo como inicio")
                                .font(.body)
                            Text("Reemplaza la pantalla de grupo por «Mi mundo».")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.tint)
                    }
                }
            } header: {
                Text("Laboratorio Ruul")
            } footer: {
                Text("Solo visible en builds de desarrollo. Apagar restaura la vista por grupo.")
            }
            #endif
        }
        .navigationTitle(L10n.PersonalSettings.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
