import SwiftUI
import RuulCore

/// R.5V.2 — Attention card canónica para HomeView + ContextDetailViewV2.
///
/// Doctrina UX §0.5: respeta las **4 prioridades attention**
/// (critical/high/normal/low) con tint diferenciado.
///
/// Cierra el gap §0.5 del R.5V.0 audit: hoy `attentionSection` renderiza
/// TODOS los items con `.orange` ignorando priority. Este componente usa
/// `AttentionItem.derivedPriority` (R.5Y.A2 Domain) para tintear correctamente.
///
/// El tap delega a `AttentionDispatcher` (R.5Y.A2) — single point of routing.
public struct RuulAttentionCard: View {
    public let items: [AttentionItem]
    public let onTap: (AttentionDestination) -> Void
    public let onSeeAll: () -> Void

    public init(
        items: [AttentionItem],
        onTap: @escaping (AttentionDestination) -> Void,
        onSeeAll: @escaping () -> Void
    ) {
        self.items = items
        self.onTap = onTap
        self.onSeeAll = onSeeAll
    }

    public var body: some View {
        if items.isEmpty {
            emptyState
        } else {
            populated
        }
    }

    // MARK: - Empty (all clear)

    @ViewBuilder
    private var emptyState: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(Theme.Tint.success)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text("Atención")
                    .font(.subheadline.weight(.semibold))
                Text("Todo está al día")
                    .font(.callout)
                    .foregroundStyle(Theme.Text.secondary)
            }
            Spacer()
        }
        .padding(Theme.Spacing.lg)
        .glassEffect(.regular.tint(highestTint.opacity(0.18)).interactive(), in: Theme.cardShape())
    }

    // MARK: - Populated

    @ViewBuilder
    private var populated: some View {
        Button {
            if items.count == 1 {
                onTap(AttentionDispatcher.destination(for: items[0]))
            } else {
                onSeeAll()
            }
        } label: {
            VStack(spacing: 0) {
                header
                Divider().padding(.leading, Theme.Spacing.lg)
                rows
            }
            .glassEffect(.regular.tint(highestTint.opacity(0.18)).interactive(), in: Theme.cardShape())
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack {
            Label("Requiere tu atención", systemImage: "exclamationmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(highestTint)
            Spacer()
            Text(items.count == 1 ? "Ver" : "Ver \(items.count)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.Text.secondary)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.Text.secondary)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.top, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.md)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md - 2) {
            ForEach(items.prefix(3)) { item in
                row(item)
            }
            if items.count > 3 {
                Text("+ \(items.count - 3) más")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary)
                    .padding(.leading, 32)
            }
        }
        .padding(Theme.Spacing.lg)
    }

    @ViewBuilder
    private func row(_ item: AttentionItem) -> some View {
        HStack(spacing: Theme.Spacing.sm + 2) {
            Image(systemName: AttentionPresentation.symbol(for: item.kind))
                .font(.callout)
                .foregroundStyle(priorityTint(item.derivedPriority))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.callout)
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                Text(item.contextDisplayName)
                    .font(.caption2)
                    .foregroundStyle(Theme.Text.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Priority → tint (UX Doctrine §0.5)

    /// Tint del header según la prioridad más alta del set.
    private var highestTint: Color {
        let highest = items.map(\.derivedPriority).min() ?? .normal
        return priorityTint(highest)
    }

    /// Mapeo canónico §0.5.
    private func priorityTint(_ priority: AttentionPriority) -> Color {
        switch priority {
        case .critical: return Theme.Tint.critical
        case .high:     return Theme.Tint.warning
        case .normal:   return Theme.Tint.info
        case .low:      return Theme.Text.tertiary
        }
    }
}

#Preview("Empty") {
    RuulAttentionCard(
        items: [],
        onTap: { _ in },
        onSeeAll: {}
    )
    .padding()
}
