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
                LabeledContent {
                    Text(L10n.PersonalSettings.appearanceHint)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                } label: {
                    Label {
                        Text(L10n.PersonalSettings.appearanceSection)
                    } icon: {
                        Image(systemName: "circle.lefthalf.filled")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(L10n.PersonalSettings.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
