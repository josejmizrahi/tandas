import SwiftUI

/// Bottom sheet con theme picker + signout. Accesible desde el botón de
/// settings en HomeView.
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
                VStack(alignment: .leading, spacing: RuulSpacing.s6) {
                    profileHeader
                        .padding(.top, RuulSpacing.s2)

                    section(title: "Apariencia") {
                        appearancePicker
                    }

                    section(title: "Cuenta") {
                        signOutButton
                    }
                }
                .padding(.horizontal, RuulSpacing.s4)
                .padding(.bottom, RuulSpacing.s7)
            }
            .background(Color.ruulBackgroundCanvas.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar") { dismiss() }
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                ToolbarItem(placement: .principal) {
                    Text("Ajustes")
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.ruulBackgroundCanvas, for: .navigationBar)
        }
    }

    private var profileHeader: some View {
        HStack(spacing: RuulSpacing.s3) {
            RuulAvatar(name: app.profile?.displayName ?? "?", size: .large)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.profile?.displayName ?? "—")
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text(app.session?.user.email ?? app.session?.user.phone ?? "")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            Text(title)
                .ruulTextStyle(RuulTypography.footnote)
                .foregroundStyle(Color.ruulTextSecondary)
                .padding(.leading, RuulSpacing.s1)
            content()
        }
    }

    private var appearancePicker: some View {
        HStack(spacing: RuulSpacing.s2) {
            ForEach(AppearanceOption.allCases) { option in
                Button {
                    appearance.wrappedValue = option
                } label: {
                    VStack(spacing: RuulSpacing.s1) {
                        Image(systemName: option.systemImage)
                            .font(.system(size: 22, weight: .medium))
                        Text(option.label)
                            .ruulTextStyle(RuulTypography.callout)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, RuulSpacing.s4)
                    .foregroundStyle(
                        appearance.wrappedValue == option
                            ? Color.ruulTextPrimary
                            : Color.ruulTextSecondary
                    )
                    .background(
                        RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                            .fill(
                                appearance.wrappedValue == option
                                    ? Color.ruulBackgroundRecessed
                                    : Color.ruulBackgroundElevated
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                            .stroke(
                                appearance.wrappedValue == option
                                    ? Color.ruulBorderStrong
                                    : Color.ruulBorderSubtle,
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
                    .ruulTextStyle(RuulTypography.body)
                Spacer()
            }
            .foregroundStyle(Color.ruulSemanticError)
            .padding(.horizontal, RuulSpacing.s4)
            .padding(.vertical, RuulSpacing.s4)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .fill(Color.ruulBackgroundElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .stroke(Color.ruulBorderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
