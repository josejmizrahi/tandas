import SwiftUI
import RuulCore

// MARK: - Conflicts (R.5B)

struct ContextDetailV2ConflictsSection: View {
    let summary: ContextConflictsSummary
    let list: ContextConflictList
    let contextId: UUID
    let context: AppContext
    let container: DependencyContainer
    let isResolvingContextConflict: Bool
    @Binding var pendingContextConflict: ContextConflictItem?
    @Binding var isShowingContextConflictDialog: Bool

    var body: some View {
        let open = summary.openCount
        let critical = summary.criticalCount
        Section {
            ForEach(list.items.prefix(4)) { item in
                conflictRow(item)
            }
            if list.items.count > 4 || list.items.count < open {
                NavigationLink {
                    ContextConflictsListView(contextActorId: contextId, context: context, container: container)
                } label: {
                    Label(
                        list.items.count < open ? "Ver \(open) conflictos" : "Ver todos (\(open))",
                        systemImage: "list.bullet"
                    )
                }
            }
        } header: {
            Text("Conflictos abiertos")
        } footer: {
            Text(conflictsSubtitle(open: open, critical: critical))
        }
    }

    @ViewBuilder
    private func conflictRow(_ item: ContextConflictItem) -> some View {
        HStack(spacing: 0) {
            NavigationLink {
                ResourceDetailViewV2(resourceId: item.resourceId, context: context, container: container)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: contextConflictSeverityIcon(item.severity))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(contextConflictSeverityTint(item.severity))
                        .symbolEffect(
                            .pulse,
                            options: .repeating,
                            isActive: item.severity == "critical"
                        )
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.conflictTypeDisplay ?? item.conflictType)
                            .font(.callout)
                            .foregroundStyle(Theme.Text.primary)
                            .lineLimit(1)
                        Text(item.resourceDisplayName ?? "Recurso")
                            .font(.caption)
                            .foregroundStyle(Theme.Text.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
            }
            Button {
                guard !isResolvingContextConflict else { return }
                pendingContextConflict = item
                isShowingContextConflictDialog = true
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(Theme.Text.secondary)
                    .padding(.leading, 4)
            }
            .buttonStyle(.borderless)
            .disabled(isResolvingContextConflict)
        }
    }

    // MARK: - R.5B.5c — Conflict helpers (preservados intactos)

    private func conflictsSubtitle(open: Int, critical: Int) -> String {
        if critical > 0 {
            return critical == open
                ? "\(critical) crítico\(critical == 1 ? "" : "s")"
                : "\(critical) crítico\(critical == 1 ? "" : "s") · \(open) abierto\(open == 1 ? "" : "s")"
        }
        return "\(open) abierto\(open == 1 ? "" : "s")"
    }

    private func contextConflictSeverityIcon(_ severity: String) -> String {
        switch severity {
        case "critical": return "exclamationmark.octagon.fill"
        case "warning":  return "exclamationmark.triangle.fill"
        case "info":     return "info.circle.fill"
        default:         return "exclamationmark.circle"
        }
    }

    private func contextConflictSeverityTint(_ severity: String) -> Color {
        switch severity {
        case "critical": return Theme.Tint.critical
        case "warning":  return Theme.Tint.warning
        case "info":     return Theme.Tint.info
        default:         return Theme.Text.secondary
        }
    }
}

// MARK: - R.5B.5c — ContextConflictsAlert + ContextConflictsModifier

struct ContextConflictsAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Aísla confirmation dialog + alert fuera del body — preempt type-checker
/// timeout (heredado de R.5B.5b — el body ya tenía 13+ modifiers, R.5V.4 +1).
struct ContextConflictsModifier: ViewModifier {
    @Binding var pendingConflict: ContextConflictItem?
    @Binding var isShowingDialog: Bool
    @Binding var alert: ContextConflictsAlert?
    @Binding var isShowingAlert: Bool
    let dialogMessage: (ContextConflictItem) -> String
    let onKind: (ContextConflictItem, ResolveResourceConflictKind) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                pendingConflict?.conflictTypeDisplay ?? "Conflicto",
                isPresented: $isShowingDialog,
                titleVisibility: .visible,
                presenting: pendingConflict
            ) { item in
                Button("Resolver manualmente") { onKind(item, .manualResolution) }
                Button("Escalar a decisión")  { onKind(item, .escalate) }
                Button("Descartar", role: .destructive) { onKind(item, .dismiss) }
                Button("Cancelar", role: .cancel) {}
            } message: { item in
                Text(dialogMessage(item))
            }
            .alert(
                alert?.title ?? "",
                isPresented: $isShowingAlert,
                presenting: alert
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { a in
                Text(a.message)
            }
    }
}
