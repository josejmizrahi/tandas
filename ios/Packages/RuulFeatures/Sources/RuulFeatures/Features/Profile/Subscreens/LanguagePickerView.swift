import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct LanguagePickerView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var error: String?

    public init() {}

    /// Beta 1 supported locales. Add new ones here once Localizable.strings
    /// has the corresponding key set verified.
    public static let supported: [(code: String, label: String)] = [
        ("es-MX", "Español (México)"),
        ("es-ES", "Español (España)"),
        ("en-US", "English (US)"),
        ("pt-BR", "Português (Brasil)"),
        ("fr-FR", "Français")
    ]

    private var current: String { app.profile?.locale ?? "es-MX" }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Self.supported, id: \.code) { entry in
                    Button {
                        Task { await select(entry.code) }
                    } label: {
                        HStack {
                            Text(entry.label)
                                .font(.subheadline)
                                .foregroundStyle(Color.primary)
                            Spacer()
                            if entry.code == current {
                                Image(systemName: "checkmark")
                                    .font(.subheadline.weight(.medium))
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
                    .padding(.horizontal, RuulSpacing.lg)
            }
        }
        .background(Color.ruulBackground.ignoresSafeArea())
        .navigationTitle("Idioma")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func select(_ code: String) async {
        guard code != current else { dismiss(); return }
        saving = true
        defer { saving = false }
        do {
            try await app.profileRepo.updateLocale(code)
            await app.refreshProfileAndGroups()
            dismiss()
        } catch {
            self.error = "No pudimos guardar tu idioma. Intenta de nuevo."
        }
    }
}
