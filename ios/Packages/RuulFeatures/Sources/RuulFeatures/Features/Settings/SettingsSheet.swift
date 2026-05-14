import SwiftUI
import RuulUI
import RuulCore

/// Bottom sheet con theme picker + signout. Accesible desde el botón de
/// settings en HomeView.
public struct SettingsSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ruul_appearance") private var appearanceRaw: String = AppearanceOption.system.rawValue

    private var appearance: Binding<AppearanceOption> {
        Binding(
            get: { AppearanceOption(rawValue: appearanceRaw) ?? .system },
            set: { appearanceRaw = $0.rawValue }
        )
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.xl) {
                    profileHeader
                        .padding(.top, RuulSpacing.xs)

                    section(title: "Apariencia") {
                        appearancePicker
                    }

                    section(title: "Cuenta") {
                        signOutButton
                    }
                }
                .padding(.horizontal, RuulSpacing.md)
                .padding(.bottom, RuulSpacing.xxl)
            }
            .background(Color.ruulBackground.ignoresSafeArea())
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
            .toolbarBackground(Color.ruulBackground, for: .navigationBar)
        }
    }

    private var profileHeader: some View {
        HStack(spacing: RuulSpacing.sm) {
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
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(title)
                .ruulTextStyle(RuulTypography.footnote)
                .foregroundStyle(Color.ruulTextSecondary)
                .padding(.leading, RuulSpacing.xxs)
            content()
        }
    }

    private var appearancePicker: some View {
        HStack(spacing: RuulSpacing.xs) {
            ForEach(AppearanceOption.allCases) { option in
                Button {
                    appearance.wrappedValue = option
                } label: {
                    VStack(spacing: RuulSpacing.xxs) {
                        Image(systemName: option.systemImage)
                            .ruulTextStyle(RuulTypography.titleMedium)
                            .accessibilityHidden(true)
                        Text(option.label)
                            .ruulTextStyle(RuulTypography.callout)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, RuulSpacing.md)
                    .foregroundStyle(
                        appearance.wrappedValue == option
                            ? Color.ruulTextPrimary
                            : Color.ruulTextSecondary
                    )
                    .background(
                        RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                            .fill(
                                appearance.wrappedValue == option
                                    ? Color.ruulBackgroundRecessed
                                    : Color.ruulSurface
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                            .stroke(
                                appearance.wrappedValue == option
                                    ? Color.ruulBorderStrong
                                    : Color.ruulSeparator,
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
                // app.signOut revokes the APNs token before clearing the
                // session, so the device stops receiving pushes addressed
                // to this user. Plain `auth.signOut()` leaks pushes to
                // the next user of a shared device.
                try? await app.signOut()
                dismiss()
            }
        } label: {
            HStack {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .ruulTextStyle(RuulTypography.subheadMedium)
                    .accessibilityHidden(true)
                Text("Cerrar sesión")
                    .ruulTextStyle(RuulTypography.body)
                Spacer()
            }
            .foregroundStyle(Color.ruulNegative)
            .padding(.horizontal, RuulSpacing.md)
            .padding(.vertical, RuulSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .fill(Color.ruulSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
