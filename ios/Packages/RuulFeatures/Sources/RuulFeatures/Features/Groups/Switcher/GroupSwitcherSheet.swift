import SwiftUI
import RuulUI
import RuulCore

/// Sheet shown when the user taps the group pill in the Home header.
/// Lists every group the user belongs to (tap a row to switch active),
/// plus two entry points: create a new group, or join one with a code.
///
/// Visual rhythm matches the rest of the app: section headers via
/// `RuulListSectionHeader`, rows in `RuulSeparatedRows` (hairline
/// dividers, no card chrome). The active row is marked with a
/// "Activo" pill on the trailing edge so tapping any non-active row
/// is obviously a switch action.
public struct GroupSwitcherSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public var onCreateGroup: () -> Void
    public var onJoinGroup: () -> Void

    public init(onCreateGroup: @escaping () -> Void, onJoinGroup: @escaping () -> Void) {
        self.onCreateGroup = onCreateGroup
        self.onJoinGroup = onJoinGroup
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
                    groupsSection
                    actionsSection
                }
                .padding(.horizontal, RuulSpacing.screenPadding)
                .padding(.top, RuulSpacing.md)
                .padding(.bottom, RuulSpacing.xxl)
            }
            .ruulAmbientScreen(palette: nil)
            .ruulSheetToolbar("Cambiar grupo")
        }
    }

    private var groupsSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            RuulListSectionHeader("TUS GRUPOS", count: app.groups.count)
            RuulSeparatedRows(items: app.groups) { group in
                groupRow(group)
            }
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            RuulListSectionHeader("MÁS OPCIONES")
            RuulSeparatedRows(items: SwitcherAction.allCases) { action in
                actionRow(action)
            }
        }
    }

    private func groupRow(_ group: RuulCore.Group) -> some View {
        let isActive = app.activeGroup?.id == group.id
        return Button {
            // DS v3 §4.3: haptic feedback al cambiar grupo activo. Solo
            // dispara cuando hay cambio real (idempotente si ya es el
            // activo). Bootstrap y push deep-links no pasan por aquí.
            if !isActive {
                app.activeGroupId = group.id
                RuulHaptic.groupSwitch.trigger()
            }
            dismiss()
        } label: {
            HStack(spacing: RuulSpacing.md) {
                RuulGroupAvatar(group: group, size: .lg)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                        .lineLimit(1)
                    Text(group.eventVocabulary.capitalized)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                Spacer(minLength: 0)
                if isActive {
                    Text("ACTIVO")
                        .ruulTextStyle(RuulTypography.sectionLabel)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .padding(.horizontal, RuulSpacing.sm)
                        .padding(.vertical, 4)
                        .overlay(
                            Capsule().stroke(Color.ruulSeparator, lineWidth: 0.5)
                        )
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, RuulSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isActive ? "\(group.name), grupo activo" : "Cambiar a \(group.name)")
    }

    private func actionRow(_ action: SwitcherAction) -> some View {
        Button {
            dismiss()
            switch action {
            case .create: onCreateGroup()
            case .join:   onJoinGroup()
            }
        } label: {
            HStack(spacing: RuulSpacing.md) {
                Image(systemName: action.icon)
                    .ruulTextStyle(RuulTypography.subheadSemibold)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .frame(width: RuulSize.avatarMedium, height: RuulSize.avatarMedium)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Text(action.subtitle)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .ruulTextStyle(RuulTypography.labelSemibold)
                    .foregroundStyle(Color.ruulTextTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, RuulSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Identifiable enum so `RuulSeparatedRows` can drive the two
    /// trailing options ("Crear nuevo grupo", "Unirme con código")
    /// with the same hairline rhythm as the groups list above.
    private enum SwitcherAction: String, CaseIterable, Identifiable {
        case create, join
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .create: return "plus"
            case .join:   return "person.badge.plus"
            }
        }

        var title: String {
            switch self {
            case .create: return "Crear nuevo grupo"
            case .join:   return "Unirme con código"
            }
        }

        var subtitle: String {
            switch self {
            case .create: return "Empieza un grupo nuevo desde cero"
            case .join:   return "Tengo un código de invitación"
            }
        }
    }
}
