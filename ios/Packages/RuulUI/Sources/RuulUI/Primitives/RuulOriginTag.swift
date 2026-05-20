import SwiftUI
import RuulCore

/// Tag pequeño que muestra de qué grupo viene un item. Usado en Home (cross-grupos)
/// arriba de cada `ActionCard` / item. Per DS v3 §3.12.
public struct RuulOriginTag: View {
    private let groupName: String
    private let initials: String?
    private let category: GroupCategory

    public init(groupName: String, initials: String? = nil, category: GroupCategory) {
        self.groupName = groupName
        self.initials = initials
        self.category = category
    }

    public var body: some View {
        HStack(spacing: 6) {
            RuulGroupAvatar(
                groupName: groupName,
                initials: initials,
                category: category,
                size: .sm
            )
            Text(groupName)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.ruulTextSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Grupo: \(groupName)")
    }
}

#if DEBUG
#Preview("RuulOriginTag") {
    VStack(alignment: .leading, spacing: RuulSpacing.md) {
        RuulOriginTag(groupName: "Cena del Jueves", category: .socialRecurring)
        RuulOriginTag(groupName: "Tanda Marzo 2026", category: .rotatingSavings)
        RuulOriginTag(groupName: "Squad Bali Trip", category: .groupTravel)
        RuulOriginTag(groupName: "Mastermind Q1", category: .professionalInformal)
    }
    .padding(RuulSpacing.lg)
    .background(Color.ruulBackground)
}
#endif
