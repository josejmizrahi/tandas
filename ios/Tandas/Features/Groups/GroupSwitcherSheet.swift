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
                VStack(alignment: .leading, spacing: RuulSpacing.s5) {
                    section(title: "Tus grupos") {
                        VStack(spacing: RuulSpacing.s2) {
                            ForEach(app.groups) { group in
                                groupRow(group)
                            }
                        }
                    }
                    section(title: "Más opciones") {
                        VStack(spacing: RuulSpacing.s2) {
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
                    Text("Grupos")
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.ruulBackgroundCanvas, for: .navigationBar)
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

    private func groupRow(_ group: Group) -> some View {
        let isActive = app.activeGroup?.id == group.id
        return Button {
            app.activeGroupId = group.id
            dismiss()
        } label: {
            HStack(spacing: RuulSpacing.s3) {
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .fill(Color.ruulAccentSubtle)
                    .frame(width: 44, height: 44)
                    .overlay(
                        Text(initials(for: group.name))
                            .ruulTextStyle(RuulTypography.headline)
                            .foregroundStyle(Color.ruulAccentPrimary)
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
                        .foregroundStyle(Color.ruulAccentPrimary)
                }
            }
            .padding(.horizontal, RuulSpacing.s4)
            .padding(.vertical, RuulSpacing.s3)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .fill(Color.ruulBackgroundElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .stroke(isActive ? Color.ruulBorderStrong : Color.ruulBorderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func actionRow(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: RuulSpacing.s3) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.ruulAccentPrimary)
                    .frame(width: 44, height: 44)
                    .background(Color.ruulAccentSubtle, in: RoundedRectangle(cornerRadius: RuulRadius.md))
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
            }
            .padding(.horizontal, RuulSpacing.s4)
            .padding(.vertical, RuulSpacing.s3)
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

    private func initials(for name: String) -> String {
        let words = name.split(separator: " ").prefix(2)
        return words.compactMap { $0.first }.map(String.init).joined().uppercased()
    }
}
