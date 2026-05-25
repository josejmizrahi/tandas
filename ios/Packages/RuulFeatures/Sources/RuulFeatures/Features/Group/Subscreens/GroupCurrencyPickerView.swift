import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct GroupCurrencyPickerView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    public let groupId: UUID

    @State private var saving = false
    @State private var error: String?

    public init(groupId: UUID) { self.groupId = groupId }

    /// Beta-1 supported currencies.
    public static let supported: [(code: String, label: String, symbol: String)] = [
        ("MXN", "Peso mexicano",        "$"),
        ("USD", "Dólar estadounidense", "US$"),
        ("EUR", "Euro",                 "€"),
        ("GBP", "Libra esterlina",      "£"),
        ("ARS", "Peso argentino",       "AR$"),
        ("BRL", "Real brasileño",       "R$"),
        ("CLP", "Peso chileno",         "CL$"),
        ("COP", "Peso colombiano",      "CO$"),
        ("PEN", "Sol peruano",          "S/")
    ]

    private var current: String {
        app.groups.first(where: { $0.id == groupId })?.currency ?? "MXN"
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Self.supported, id: \.code) { entry in
                    Button { Task { await select(entry.code) } } label: {
                        HStack {
                            Text(entry.symbol)
                                .font(.body.monospaced())
                                .frame(width: 44, alignment: .leading)
                                .foregroundStyle(Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.label)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.primary)
                                Text(entry.code)
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary)
                            }
                            Spacer()
                            if entry.code == current {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.ruulAccent)
                            }
                        }
                        .padding(RuulSpacing.md)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(saving)
                    if entry.code != Self.supported.last?.code {
                        Divider().background(Color(.separator)).padding(.leading, RuulSpacing.md)
                    }
                }
            }
            .ruulCardSurface(.solid)
            .padding(RuulSpacing.lg)
            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Color.red)
            }
        }
        .background(Color.ruulBackground.ignoresSafeArea())
        .navigationTitle("Moneda del grupo")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func select(_ code: String) async {
        guard code != current else { dismiss(); return }
        saving = true
        defer { saving = false }
        do {
            _ = try await app.groupsRepo.updateConfig(
                groupId: groupId,
                patch: GroupConfigPatch(currency: code)
            )
            await app.refreshProfileAndGroups()
            dismiss()
        } catch {
            self.error = "No pudimos cambiar la moneda."
        }
    }
}
