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

    /// WWDC26 — el slot cambia entre `.inline` (tab bar minimizado, junto a la
    /// barra, espacio reducido) y `.expanded` (sobre la barra, ancho completo).
    /// Adaptamos el contenido en vez de renderizar siempre la fila completa.
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    public init(item: AttentionItem, totalCount: Int, onTap: @escaping () -> Void) {
        self.item = item
        self.totalCount = totalCount
        self.onTap = onTap
    }

    private var isInline: Bool { placement == .inline }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: isInline ? 8 : 12) {
                icon
                if isInline {
                    Text(inlineLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                } else {
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
            }
            .padding(.horizontal, isInline ? 12 : 16)
            .padding(.vertical, isInline ? 6 : 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(item.title), \(subtitle)"))
        .accessibilityHint(Text("Abrir atención pendiente"))
    }

    /// Ícono con badge de conteo cuando hay más de un pendiente — glanceable
    /// tanto inline como expanded.
    private var icon: some View {
        Image(systemName: AttentionPresentation.symbol(for: item.kind))
            .font(.title3)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(AttentionPresentation.tint(for: item.kind))
            .symbolEffect(.pulse, options: .repeating, isActive: item.derivedPriority == .critical)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 28)
            .overlay(alignment: .topTrailing) {
                if totalCount > 1 {
                    Text("\(min(totalCount, 99))")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(AttentionPresentation.tint(for: item.kind), in: Capsule())
                        .offset(x: 8, y: -6)
                }
            }
    }

    /// Inline: espacio reducido → título corto o el conteo total.
    private var inlineLabel: String {
        totalCount > 1 ? "\(totalCount) pendientes" : item.title
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
