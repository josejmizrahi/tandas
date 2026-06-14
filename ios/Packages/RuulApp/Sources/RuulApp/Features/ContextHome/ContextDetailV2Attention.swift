import SwiftUI
import RuulCore

// MARK: - Attention

struct ContextDetailV2AttentionSection: View {
    let items: [AttentionItem]
    @Binding var presentedAttention: AttentionDestination?
    @Binding var isShowingAllAttention: Bool

    var body: some View {
        Section {
            if items.isEmpty {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Todo al día").font(.callout.weight(.medium))
                        Text("Sin pendientes en este espacio")
                            .font(.caption)
                            .foregroundStyle(Theme.Text.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Tint.success)
                }
            } else {
                ForEach(items.prefix(3)) { item in
                    Button {
                        presentedAttention = AttentionDispatcher.destination(for: item)
                    } label: {
                        ContextDetailV2AttentionRow(item: item)
                    }
                }
                if items.count > 3 {
                    Button {
                        isShowingAllAttention = true
                    } label: {
                        Label("Ver todos los pendientes (\(items.count))", systemImage: "list.bullet")
                    }
                }
            }
        } header: {
            Text("Atención")
        }
    }
}

struct ContextDetailV2AttentionRow: View {
    let item: AttentionItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: AttentionPresentation.symbol(for: item.kind))
                .foregroundStyle(attentionPriorityTint(item.derivedPriority))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.callout)
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                Text(AttentionPresentation.ctaLabel(for: item.kind))
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
            }
            Spacer()
        }
    }

    private func attentionPriorityTint(_ priority: AttentionPriority) -> Color {
        switch priority {
        case .critical: return Theme.Tint.critical
        case .high:     return Theme.Tint.warning
        case .normal:   return Theme.Tint.info
        case .low:      return Theme.Text.tertiary
        }
    }
}

// MARK: - Sheet "Todos los pendientes" (V2)

struct AllContextAttentionViewV2: View {
    let items: [AttentionItem]
    let onTap: (AttentionItem) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(items) { item in
                Button {
                    onTap(item)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: AttentionPresentation.symbol(for: item.kind))
                            .foregroundStyle(AttentionPresentation.tint(for: item.kind))
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.callout.weight(.medium))
                            Text(item.reason)
                                .font(.caption).foregroundStyle(Theme.Text.secondary).lineLimit(2)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.Text.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Pendientes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cerrar") { dismiss() }
            }
        }
    }
}
