import SwiftUI

/// Reusable filterable IANA timezone picker.
/// The owner provides `current` and reacts to `onSelect`. Picker handles
/// search + offset display; persistence is the caller's responsibility.
public struct TimezonePicker: View {
    public let current: String
    public let onSelect: (String) async -> Void

    @State private var query = ""
    @State private var saving = false

    public init(current: String, onSelect: @escaping (String) async -> Void) {
        self.current = current
        self.onSelect = onSelect
    }

    private var allZones: [String] { TimeZone.knownTimeZoneIdentifiers.sorted() }
    private var filteredZones: [String] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return allZones }
        let q = query.lowercased()
        return allZones.filter { $0.lowercased().contains(q) }
    }

    public var body: some View {
        List {
            ForEach(filteredZones, id: \.self) { tz in
                Button {
                    Task {
                        saving = true
                        await onSelect(tz)
                        saving = false
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tz)
                                .font(.subheadline)
                                .foregroundStyle(Color.ruulTextPrimary)
                            Text(offsetLabel(for: tz))
                                .font(.caption)
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
    }

    private func offsetLabel(for tz: String) -> String {
        guard let zone = TimeZone(identifier: tz) else { return "" }
        let seconds = zone.secondsFromGMT()
        let hours = seconds / 3600
        let minutes = abs((seconds % 3600) / 60)
        let sign = seconds >= 0 ? "+" : "-"
        return String(format: "GMT%@%02d:%02d", sign, abs(hours), minutes)
    }
}
