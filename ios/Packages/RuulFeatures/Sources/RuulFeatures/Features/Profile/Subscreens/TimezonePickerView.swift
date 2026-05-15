import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct TimezonePickerView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        TimezonePicker(
            current: app.profile?.timezone ?? TimeZone.current.identifier,
            onSelect: { tz in
                guard tz != (app.profile?.timezone ?? "") else { dismiss(); return }
                do {
                    try await app.profileRepo.updateTimezone(tz)
                    await app.refreshProfileAndGroups()
                    dismiss()
                } catch {
                    // Picker shows nothing; consider a Toast in a follow-up.
                }
            }
        )
        .navigationTitle("Zona horaria")
        .navigationBarTitleDisplayMode(.inline)
    }
}
