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

    /// Pinned group IDs persistidos en UserDefaults. Cross-device sync
    /// es nice-to-have V2 (no critical state) — local first-write wins.
    @AppStorage("ruul.switcher.pinnedGroupIds") private var pinnedIdsCSV: String = ""

    public init(onCreateGroup: @escaping () -> Void, onJoinGroup: @escaping () -> Void) {
        self.onCreateGroup = onCreateGroup
        self.onJoinGroup = onJoinGroup
    }

    private var pinnedIds: Set<UUID> {
        Set(pinnedIdsCSV.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    /// Pinned groups first (in their original order), then unpinned.
    /// Keeps stable ordering within each bucket.
    private var sortedGroups: [RuulCore.Group] {
        let pinned = pinnedIds
        return app.groups.sorted { a, b in
            let aP = pinned.contains(a.id)
            let bP = pinned.contains(b.id)
            if aP != bP { return aP }
            return false  // stable
        }
    }

    private func togglePin(_ groupId: UUID) {
        var current = pinnedIds
        if current.contains(groupId) {
            current.remove(groupId)
        } else {
            current.insert(groupId)
        }
        pinnedIdsCSV = current.map { $0.uuidString }.joined(separator: ",")
        RuulHaptic.groupSwitch.trigger()
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
            .ruulSheetToolbar("Cambiar grupo")
        }
    }

    private var groupsSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: RuulSpacing.xs) {
                Text("Tus grupos")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                Spacer(minLength: 0)
                Text("\(app.groups.count)")
                    .font(.footnote.monospacedDigit().weight(.bold))
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            RuulSeparatedRows(items: sortedGroups) { group in
                groupRow(group)
            }
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            Text("Más opciones").font(.footnote.weight(.semibold)).foregroundStyle(Color(.tertiaryLabel))
            RuulSeparatedRows(items: SwitcherAction.allCases) { action in
                actionRow(action)
            }
        }
    }

    private func groupRow(_ group: RuulCore.Group) -> some View {
        let isActive = app.activeGroup?.id == group.id
        let isPinned = pinnedIds.contains(group.id)
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
                    HStack(spacing: RuulSpacing.xs) {
                        Text(group.name)
                            .font(.subheadline)
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)
                        if isPinned {
                            Image(systemName: "pin.fill")
                                .font(.caption)
                                .foregroundStyle(Color.ruulAccent)
                                .accessibilityLabel("Fijado")
                        }
                    }
                    Text(group.eventVocabulary.capitalized)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                Spacer(minLength: 0)
                if isActive {
                    Text("Activo")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                        .padding(.horizontal, RuulSpacing.sm)
                        .padding(.vertical, 4)
                        .overlay(
                            Capsule().stroke(Color(.separator), lineWidth: 0.5)
                        )
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, RuulSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isActive ? "\(group.name), grupo activo" : "Cambiar a \(group.name)")
        .swipeActions(edge: .leading) {
            Button {
                togglePin(group.id)
            } label: {
                Label(isPinned ? "Desfijar" : "Fijar",
                      systemImage: isPinned ? "pin.slash.fill" : "pin.fill")
            }
            .tint(Color.ruulAccent)
        }
        .contextMenu {
            Button {
                togglePin(group.id)
            } label: {
                Label(isPinned ? "Desfijar grupo" : "Fijar al inicio",
                      systemImage: isPinned ? "pin.slash" : "pin")
            }
        }
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
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                    Text(action.subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
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
