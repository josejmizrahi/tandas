import SwiftUI
import RuulCore

/// Lightweight readiness card mounted in `GroupHomeView`. Renders
/// the five Foundation primitives as a checklist + an overall
/// summary. Tapping an incomplete row navigates to the matching
/// existing surface via a closure (the parent owns the destinations).
public struct FoundationStatusCard: View {
    @Bindable var store: FoundationStatusStore
    let onSelect: (FoundationPrimitiveKind) -> Void

    public init(
        store: FoundationStatusStore,
        onSelect: @escaping (FoundationPrimitiveKind) -> Void
    ) {
        self.store = store
        self.onSelect = onSelect
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch store.phase {
            case .idle, .loading:
                placeholderRows
            case .failed(let message):
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            case .loaded:
                if let status = store.status {
                    rows(for: status)
                } else {
                    placeholderRows
                }
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func rows(for status: GroupFoundationStatus) -> some View {
        ForEach(FoundationPrimitiveKind.displayOrder, id: \.self) { kind in
            let primitive = status.primitive(for: kind)
            row(kind: kind, primitive: primitive)
            if kind != FoundationPrimitiveKind.displayOrder.last {
                Divider().padding(.leading, 36)
            }
        }
        Divider().padding(.leading, 36)
        summaryRow(for: status)
    }

    @ViewBuilder
    private func row(kind: FoundationPrimitiveKind, primitive: GroupFoundationPrimitive) -> some View {
        Button {
            // Even complete rows are tap-targets (navigation is harmless);
            // the incomplete affordance is purely cosmetic.
            onSelect(kind)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: kind.systemImageName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(primitive.isComplete ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(label(for: kind))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let detail = rowDetail(for: kind, primitive: primitive) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: primitive.isComplete
                      ? "checkmark.circle.fill"
                      : "circle.dashed")
                    .font(.body)
                    .foregroundStyle(primitive.isComplete ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(primitive.isComplete
                                ? L10n.Foundation.completeLabel
                                : L10n.Foundation.incompleteLabel))
    }

    @ViewBuilder
    private func summaryRow(for status: GroupFoundationStatus) -> some View {
        HStack {
            Text(status.isReady ? L10n.Foundation.readySummary : L10n.Foundation.notReadySummary)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(status.isReady ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Spacer()
            Text("\(store.completeCount)/5")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var placeholderRows: some View {
        ForEach(FoundationPrimitiveKind.displayOrder, id: \.self) { kind in
            HStack(spacing: 12) {
                Image(systemName: kind.systemImageName)
                    .frame(width: 24)
                Text(label(for: kind))
                    .font(.body.weight(.semibold))
                Spacer()
                ProgressView()
                    .controlSize(.small)
            }
            .padding(.vertical, 6)
            .redacted(reason: .placeholder)
        }
    }

    private func label(for kind: FoundationPrimitiveKind) -> LocalizedStringResource {
        switch kind {
        case .members:   return L10n.Foundation.membersLabel
        case .boundary:  return L10n.Foundation.boundaryLabel
        case .purpose:   return L10n.Foundation.purposeLabel
        case .rules:     return L10n.Foundation.rulesLabel
        case .resources: return L10n.Foundation.resourcesLabel
        }
    }

    private func rowDetail(for kind: FoundationPrimitiveKind,
                           primitive: GroupFoundationPrimitive) -> String? {
        switch kind {
        case .members:
            return primitive.activeCount.map { "\($0) activos" }
        case .boundary:
            let active = primitive.activeCount ?? 0
            let pending = primitive.pendingInvitesCount ?? 0
            return "\(active) activos · \(pending) pendientes"
        case .purpose, .rules, .resources:
            return primitive.activeCount.map { "\($0)" }
        }
    }
}
