import SwiftUI
import RuulCore

/// Bottom sheet que lista todos los grupos del usuario con visual ramp.
/// Tap en grupo lo activa + dismiss. Per DS v3 §3.14.
///
/// **Coexiste con** `Features/Groups/GroupSwitcherSheet.swift` legacy.
/// Fase 4 (tab restructure) migra callsites y elimina la legacy.
public struct RuulGroupSwitcherSheet: View {
    public struct GroupItem: Identifiable, Sendable, Hashable {
        public let id: UUID
        public let name: String
        public let initials: String?
        public let category: GroupCategory
        public let imageURL: URL?

        public init(
            id: UUID,
            name: String,
            initials: String? = nil,
            category: GroupCategory,
            imageURL: URL? = nil
        ) {
            self.id = id
            self.name = name
            self.initials = initials
            self.category = category
            self.imageURL = imageURL
        }
    }

    private let groups: [GroupItem]
    @Binding private var activeGroupId: UUID
    private let onCreate: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    public init(
        groups: [GroupItem],
        activeGroupId: Binding<UUID>,
        onCreate: (() -> Void)? = nil
    ) {
        self.groups = groups
        self._activeGroupId = activeGroupId
        self.onCreate = onCreate
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: RuulSpacing.xs) {
                    ForEach(groups) { group in
                        Button {
                            RuulHaptic.groupSwitch.trigger()
                            withAnimation(.ruulGroupSwitch) {
                                activeGroupId = group.id
                            }
                            dismiss()
                        } label: {
                            row(for: group)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, RuulSpacing.screenPadding)
                .padding(.top, RuulSpacing.md)
            }
            .background(Color.ruulBackground)
            .navigationTitle("Tus grupos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
                if let onCreate {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            dismiss()
                            onCreate()
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(for group: GroupItem) -> some View {
        HStack(spacing: RuulSpacing.md) {
            RuulGroupAvatar(
                groupName: group.name,
                initials: group.initials,
                category: group.category,
                imageURL: group.imageURL,
                size: .lg
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.ruulTitleSmall)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text(group.category.displayName)
                    .font(.ruulCaption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }

            Spacer()

            if group.id == activeGroupId {
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.ruulAccent)
            }
        }
        .padding(RuulSpacing.md)
        .background(Color.ruulSurface)
        .clipShape(RoundedRectangle(cornerRadius: RuulRadius.large))
    }
}

#if DEBUG
#Preview("RuulGroupSwitcherSheet") {
    @Previewable @State var activeId = UUID()
    let groups: [RuulGroupSwitcherSheet.GroupItem] = [
        .init(id: activeId, name: "Cena del Jueves", category: .socialRecurring),
        .init(id: UUID(), name: "Tanda Marzo 2026", category: .rotatingSavings),
        .init(id: UUID(), name: "Squad Bali Trip", category: .groupTravel),
        .init(id: UUID(), name: "Mastermind Q1", category: .professionalInformal),
    ]
    return RuulGroupSwitcherSheet(
        groups: groups,
        activeGroupId: $activeId,
        onCreate: { print("create group") }
    )
}
#endif
