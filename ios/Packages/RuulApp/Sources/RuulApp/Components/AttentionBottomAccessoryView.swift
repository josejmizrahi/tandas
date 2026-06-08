import SwiftUI
import RuulCore

/// R.5Y.A3 — Vista para `tabViewBottomAccessory` (iOS 26+).
///
/// Muestra el item de atención más prioritario cross-context pegado encima del
/// tab bar Liquid Glass. Tap → resuelve via `AttentionDispatcher` + sheet.
///
/// Founder doctrina (R.5Y): cualquier kind futuro entra sin tocar esta vista —
/// solo presenta `AttentionPresentation.symbol/tint` canónicos y delega routing.
public struct AttentionBottomAccessoryView: View {
    let item: AttentionItem
    let totalCount: Int
    let onTap: () -> Void

    public init(item: AttentionItem, totalCount: Int, onTap: @escaping () -> Void) {
        self.item = item
        self.totalCount = totalCount
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: AttentionPresentation.symbol(for: item.kind))
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(AttentionPresentation.tint(for: item.kind))
                    .symbolEffect(
                        .pulse,
                        options: .repeating,
                        isActive: item.derivedPriority == .critical
                    )
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(item.title), \(subtitle)"))
        .accessibilityHint(Text("Abrir atención pendiente"))
    }

    private var subtitle: String {
        let context = item.contextDisplayName
        let extras = totalCount - 1
        guard extras > 0 else { return context }
        return "\(context) · +\(extras) pendiente\(extras == 1 ? "" : "s")"
    }
}

// MARK: - Selection helper

extension AttentionInboxStore {
    /// Ranks items by derived priority (critical first) and returns the top one.
    /// Used by `MainTabShell` to feed `tabViewBottomAccessory`.
    public var topPriorityItem: AttentionItem? {
        items.min(by: { $0.derivedPriority < $1.derivedPriority })
    }
}

// MARK: - Previews

#Preview("1 item — decision") {
    AttentionBottomAccessoryView(
        item: .previewDecision,
        totalCount: 1,
        onTap: {}
    )
    .frame(maxWidth: .infinity)
    .background(.regularMaterial)
}

#Preview("3 items — conflict critical") {
    AttentionBottomAccessoryView(
        item: .previewConflict,
        totalCount: 3,
        onTap: {}
    )
    .frame(maxWidth: .infinity)
    .background(.regularMaterial)
}

private extension AttentionItem {
    static var previewDecision: AttentionItem {
        AttentionItem(
            kind: "decision_vote",
            subjectId: UUID(),
            contextActorId: UUID(),
            contextDisplayName: "Cena Semanal",
            title: "Faltan tus votos",
            reason: "Vota para cerrar la decisión",
            ctaActionKey: "vote_decision",
            ctaScopeKind: "decision",
            ctaScopeId: UUID(),
            occurredAt: Date(),
            amount: nil,
            currency: nil,
            counterpartyName: nil,
            resourceId: nil
        )
    }

    static var previewConflict: AttentionItem {
        AttentionItem(
            kind: "reservation_conflict",
            subjectId: UUID(),
            contextActorId: UUID(),
            contextDisplayName: "Familia Mizrahi",
            title: "Conflicto en Casa Valle",
            reason: "Dos reservas se traslapan",
            ctaActionKey: "resolve_conflict",
            ctaScopeKind: "reservation_conflict",
            ctaScopeId: UUID(),
            occurredAt: Date(),
            amount: nil,
            currency: nil,
            counterpartyName: nil,
            resourceId: UUID()
        )
    }
}
