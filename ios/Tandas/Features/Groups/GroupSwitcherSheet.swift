import SwiftUI

/// Sheet shown when the user taps the group name in HomeView header.
/// Lists every group the user belongs to (tap to switch active), plus
/// two entry points: create a new group, or join one with an invite code.
struct GroupSwitcherSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var onCreateGroup: () -> Void
    var onJoinGroup: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                    section(title: "Tus grupos") {
                        VStack(spacing: RuulSpacing.xs) {
                            ForEach(app.groups) { group in
                                groupRow(group)
                            }
                        }
                    }
                    section(title: "Más opciones") {
                        VStack(spacing: RuulSpacing.xs) {
                            actionRow(
                                icon: "plus.circle.fill",
                                title: "Crear nuevo grupo",
                                subtitle: "Empieza un grupo nuevo desde cero"
                            ) {
                                dismiss()
                                onCreateGroup()
                            }
                            actionRow(
                                icon: "person.badge.plus",
                                title: "Unirme con código",
                                subtitle: "Tengo un código de invitación"
                            ) {
                                dismiss()
                                onJoinGroup()
                            }
                        }
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
                    Text("Grupos")
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.ruulBackground, for: .navigationBar)
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

    private func groupRow(_ group: Group) -> some View {
        let isActive = app.activeGroup?.id == group.id
        return Button {
            app.activeGroupId = group.id
            dismiss()
        } label: {
            HStack(spacing: RuulSpacing.sm) {
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .fill(Color.ruulAccentMuted)
                    .frame(width: 44, height: 44)
                    .overlay(
                        Text(initials(for: group.name))
                            .ruulTextStyle(RuulTypography.headline)
                            .foregroundStyle(Color.ruulAccent)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                        .lineLimit(1)
                    Text(group.eventVocabulary.capitalized)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color.ruulAccent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, RuulSpacing.md)
            .padding(.vertical, RuulSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .fill(Color.ruulSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .stroke(isActive ? Color.ruulBorderStrong : Color.ruulSeparator, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func actionRow(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.ruulAccent)
                    .frame(width: 44, height: 44)
                    .background(Color.ruulAccentMuted, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Text(subtitle)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ruulTextTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, RuulSpacing.md)
            .padding(.vertical, RuulSpacing.sm)
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

    private func initials(for name: String) -> String {
        let words = name.split(separator: " ").prefix(2)
        return words.compactMap { $0.first }.map(String.init).joined().uppercased()
    }
}
