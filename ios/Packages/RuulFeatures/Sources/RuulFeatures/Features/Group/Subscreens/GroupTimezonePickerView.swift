import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct GroupTimezonePickerView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    public let groupId: UUID

    public init(groupId: UUID) { self.groupId = groupId }

    private var current: String {
        app.groups.first(where: { $0.id == groupId })?.timezone ?? TimeZone.current.identifier
    }

    public var body: some View {
        TimezonePicker(
            current: current,
            onSelect: { tz in
                guard tz != current else { dismiss(); return }
                do {
                    _ = try await app.groupsRepo.updateConfig(
                        groupId: groupId,
                        patch: GroupConfigPatch(timezone: tz)
                    )
                    await app.refreshProfileAndGroups()
                    dismiss()
                } catch { /* see TODO note in TimezonePickerView */ }
            }
        )
        .navigationTitle("Zona del grupo")
        .navigationBarTitleDisplayMode(.inline)
    }
}
