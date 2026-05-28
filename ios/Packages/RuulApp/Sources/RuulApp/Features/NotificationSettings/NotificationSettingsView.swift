import SwiftUI
import RuulCore

/// B7 — caller's notification preferences for a single group.
/// Renders the canonical category × channel grid; each toggle fires
/// `set_notification_preference(...)` optimistically.
public struct NotificationSettingsView: View {
    @Bindable var store: NotificationSettingsStore
    let groupId: UUID

    public init(store: NotificationSettingsStore, groupId: UUID) {
        self.store = store
        self.groupId = groupId
    }

    public var body: some View {
        List {
            switch store.phase {
            case .idle, .loading:
                Section {
                    HStack { ProgressView(); Text("Cargando…").foregroundStyle(.secondary) }
                }
            case .failed(let message):
                Section {
                    ContentUnavailableView {
                        Label(L10n.NotificationSettings.errorTitle, systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button(String(localized: L10n.NotificationSettings.retry)) {
                            Task { await store.refresh(groupId: groupId) }
                        }
                    }
                }
            case .loaded:
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.NotificationSettings.headline).font(.headline)
                        Text(L10n.NotificationSettings.hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                ForEach(NotificationCategory.displayOrder) { category in
                    Section {
                        ForEach(NotificationChannel.userSelectable) { channel in
                            Toggle(isOn: binding(for: category, channel: channel)) {
                                Label(channel.label, systemImage: channel.systemImageName)
                            }
                        }
                    } header: {
                        HStack {
                            Label(category.label, systemImage: category.systemImageName)
                            Spacer()
                        }
                    } footer: {
                        Text(category.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(L10n.NotificationSettings.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await store.refresh(groupId: groupId)
        }
        .task {
            await store.refreshIfNeeded(groupId: groupId)
        }
    }

    private func binding(for category: NotificationCategory, channel: NotificationChannel) -> Binding<Bool> {
        Binding(
            get: { store.isEnabled(category: category, channel: channel) },
            set: { newValue in
                Task {
                    _ = await store.setEnabled(
                        groupId: groupId,
                        category: category,
                        channel: channel,
                        enabled: newValue
                    )
                }
            }
        )
    }
}
