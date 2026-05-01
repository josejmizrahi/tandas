import SwiftUI

/// Bottom sheet con theme picker + signout. Accesible tocando el avatar.
struct SettingsSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ruul_appearance") private var appearanceRaw: String = AppearanceOption.system.rawValue

    private var appearance: Binding<AppearanceOption> {
        Binding(
            get: { AppearanceOption(rawValue: appearanceRaw) ?? .system },
            set: { appearanceRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    profileHeader
                        .padding(.top, 8)

                    section(title: "Apariencia") {
                        appearancePicker
                    }

                    section(title: "Cuenta") {
                        signOutButton
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Brand.Surface.canvas.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar") { dismiss() }
                        .foregroundStyle(Brand.Surface.textSecondary)
                }
                ToolbarItem(placement: .principal) {
                    Text("Ajustes")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Brand.Surface.textPrimary)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Brand.Surface.canvas, for: .navigationBar)
        }
    }

    private var profileHeader: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Brand.Surface.cardPressed)
                .frame(width: 56, height: 56)
                .overlay(
                    Text(initial)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Brand.Surface.textPrimary)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(app.profile?.displayName ?? "—")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Brand.Surface.textPrimary)
                Text(app.session?.user.email ?? app.session?.user.phone ?? "")
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.Surface.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    private var initial: String {
        let name = app.profile?.displayName ?? ""
        return String(name.prefix(1)).uppercased()
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Brand.Surface.textSecondary)
                .tracking(0.3)
                .textCase(.uppercase)
                .padding(.leading, 4)
            content()
        }
    }

    private var appearancePicker: some View {
        HStack(spacing: 8) {
            ForEach(AppearanceOption.allCases) { option in
                Button {
                    appearance.wrappedValue = option
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: option.systemImage)
                            .font(.system(size: 22, weight: .medium))
                        Text(option.label)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(
                        appearance.wrappedValue == option
                            ? Brand.Surface.textPrimary
                            : Brand.Surface.textSecondary
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                appearance.wrappedValue == option
                                    ? Brand.Surface.cardPressed
                                    : Brand.Surface.card
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(
                                appearance.wrappedValue == option
                                    ? Brand.Surface.textPrimary.opacity(0.20)
                                    : Brand.Surface.border,
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.selection, trigger: appearance.wrappedValue)
            }
        }
    }

    private var signOutButton: some View {
        Button {
            Task {
                try? await app.auth.signOut()
                dismiss()
            }
        } label: {
            HStack {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 16, weight: .medium))
                Text("Cerrar sesión")
                    .font(.system(size: 15, weight: .medium))
                Spacer()
            }
            .foregroundStyle(.red)
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Brand.Surface.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Brand.Surface.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
