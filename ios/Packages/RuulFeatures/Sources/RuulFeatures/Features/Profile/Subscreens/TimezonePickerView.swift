import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct TimezonePickerView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var saving = false
    @State private var error: String?

    public init() {}

    private var allZones: [String] { TimeZone.knownTimeZoneIdentifiers.sorted() }
    private var current: String { app.profile?.timezone ?? TimeZone.current.identifier }

    private var filteredZones: [String] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return allZones }
        let q = query.lowercased()
        return allZones.filter { $0.lowercased().contains(q) }
    }

    public var body: some View {
        List {
            ForEach(filteredZones, id: \.self) { tz in
                Button {
                    Task { await select(tz) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tz)
                                .ruulTextStyle(RuulTypography.body)
                                .foregroundStyle(Color.ruulTextPrimary)
                            Text(offsetLabel(for: tz))
                                .ruulTextStyle(RuulTypography.caption)
                                .foregroundStyle(Color.ruulTextSecondary)
                        }
                        Spacer()
                        if tz == current {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.ruulAccent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(saving)
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, prompt: "Buscar zona")
        .background(Color.ruulBackground.ignoresSafeArea())
        .navigationTitle("Zona horaria")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let error {
                Text(error)
                    .ruulTextStyle(RuulTypography.footnote)
                    .foregroundStyle(Color.ruulNegative)
                    .padding(RuulSpacing.md)
                    .background(Color.ruulSurface, in: Capsule())
            }
        }
    }

    private func offsetLabel(for tz: String) -> String {
        guard let zone = TimeZone(identifier: tz) else { return "" }
        let seconds = zone.secondsFromGMT()
        let hours = seconds / 3600
        let minutes = abs((seconds % 3600) / 60)
        let sign = seconds >= 0 ? "+" : "-"
        return String(format: "GMT%@%02d:%02d", sign, abs(hours), minutes)
    }

    private func select(_ tz: String) async {
        guard tz != current else { dismiss(); return }
        saving = true
        defer { saving = false }
        do {
            try await app.profileRepo.updateTimezone(tz)
            await app.refreshProfileAndGroups()
            dismiss()
        } catch {
            self.error = "No pudimos guardar tu zona horaria."
        }
    }
}
