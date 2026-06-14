import SwiftUI
import RuulCore

/// R.5B.5c — vista cross-resource de conflictos del contexto.
///
/// Push desde la conflictsCard de ContextDetailViewV2 cuando el user toca
/// "Ver \(N)" o "Ver todos". Lista TODO los conflicts abiertos agrupados por
/// severity (critical → warning → info). Cada row push a ResourceDetailViewV2;
/// trailing ellipsis abre el confirmationDialog de 3 kinds.
///
/// Carga vía `list_context_conflicts(p_context_actor_id, include_resolved=false)`.
public struct ContextConflictsListView: View {
    let contextActorId: UUID
    let context: AppContext
    let container: DependencyContainer

    @State private var list: ContextConflictList = .empty
    @State private var phase: LoadPhase = .idle
    @State private var pendingConflict: ContextConflictItem?
    @State private var isShowingDialog = false
    @State private var resolveAlert: ContextConflictsListAlert?
    @State private var isShowingAlert = false
    @State private var isResolving = false

    public init(contextActorId: UUID, context: AppContext, container: DependencyContainer) {
        self.contextActorId = contextActorId
        self.context = context
        self.container = container
    }

    private enum LoadPhase: Equatable {
        case idle, loading, loaded, failed(String)
    }

    public var body: some View {
        rootContent
            .modifier(ContextConflictsListModifier(
                pendingConflict: $pendingConflict,
                isShowingDialog: $isShowingDialog,
                alert: $resolveAlert,
                isShowingAlert: $isShowingAlert,
                onKind: { item, kind in resolve(item, kind: kind) }
            ))
    }

    @ViewBuilder
    private var rootContent: some View {
        Group {
            switch phase {
            case .idle, .loading:
                RuulLoadingState()
            case .failed(let message):
                RuulErrorState(message: message) {
                    Task { await load() }
                }
            case .loaded:
                if list.items.isEmpty {
                    emptyState
                } else {
                    listView
                }
            }
        }
        .navigationTitle("Conflictos")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Sin conflictos abiertos")
                .font(.title3.bold())
            Text("No hay conflictos pendientes de resolver en este espacio.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Spacing.xl)
    }

    @ViewBuilder
    private var listView: some View {
        let grouped = groupedBySeverity(list.items)
        List {
            ForEach(severityOrder.filter { grouped[$0] != nil }, id: \.self) { sev in
                Section {
                    ForEach(grouped[sev] ?? []) { item in
                        ContextConflictRow(
                            item: item,
                            context: context,
                            container: container,
                            isResolving: isResolving
                        ) {
                            pendingConflict = item
                            isShowingDialog = true
                        }
                    }
                } header: {
                    Text(severityHeader(sev, count: grouped[sev]?.count ?? 0))
                        .font(.subheadline.bold())
                        .foregroundStyle(severityTint(sev))
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Grouping

    private let severityOrder = ["critical", "warning", "info"]

    private func groupedBySeverity(_ items: [ContextConflictItem]) -> [String: [ContextConflictItem]] {
        Dictionary(grouping: items) { $0.severity.isEmpty ? "warning" : $0.severity }
    }

    private func severityHeader(_ severity: String, count: Int) -> String {
        let label: String
        switch severity {
        case "critical": label = "Críticos"
        case "warning":  label = "Atención"
        case "info":     label = "Informativos"
        default:         label = severity.capitalized
        }
        return "\(label) · \(count)"
    }

    private func severityTint(_ severity: String) -> Color {
        switch severity {
        case "critical": return .red
        case "warning":  return .orange
        case "info":     return .blue
        default:         return .secondary
        }
    }

    // MARK: - Load + resolve

    private func load() async {
        if list.items.isEmpty { phase = .loading }
        do {
            list = try await container.rpc.listContextConflicts(
                contextActorId: contextActorId, includeResolved: false
            )
            phase = .loaded
        } catch {
            phase = .failed(UserFacingError.from(error).message)
        }
    }

    private func resolve(_ item: ContextConflictItem, kind: ResolveResourceConflictKind) {
        guard !isResolving else { return }
        isResolving = true
        Task { @MainActor in
            defer { isResolving = false }
            do {
                let result = try await container.rpc.resolveResourceConflict(
                    conflictId: item.conflictId,
                    kind: kind,
                    winnerActorId: nil,
                    payload: .object([:])
                )
                await load()
                if result.noOp {
                    resolveAlert = ContextConflictsListAlert(
                        title: "Sin cambios",
                        message: "El conflicto ya no estaba abierto."
                    )
                } else {
                    resolveAlert = ContextConflictsListAlert(
                        title: successTitle(kind),
                        message: successMessage(kind, result: result)
                    )
                }
                isShowingAlert = true
            } catch {
                resolveAlert = ContextConflictsListAlert(
                    title: "No pudimos resolver",
                    message: UserFacingError.from(error).message
                )
                isShowingAlert = true
            }
        }
    }

    private func successTitle(_ kind: ResolveResourceConflictKind) -> String {
        switch kind {
        case .manualResolution: return "Resuelto"
        case .escalate:         return "Escalado"
        case .dismiss:          return "Descartado"
        }
    }

    private func successMessage(_ kind: ResolveResourceConflictKind, result: ResolveResourceConflictResult) -> String {
        switch kind {
        case .manualResolution: return "El conflicto quedó resuelto."
        case .escalate:
            if let tmpl = result.templateKey {
                return "Se creó una decisión (\(tmpl)) para resolver el conflicto."
            }
            return "Se creó una decisión para resolver el conflicto."
        case .dismiss: return "El conflicto fue descartado."
        }
    }
}

// MARK: - Row (push a ResourceDetailViewV2)

private struct ContextConflictRow: View {
    let item: ContextConflictItem
    let context: AppContext
    let container: DependencyContainer
    let isResolving: Bool
    let onActionsTap: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            NavigationLink {
                ResourceDetailViewV2(resourceId: item.resourceId, context: context, container: container)
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: icon)
                        .font(.system(size: Theme.IconSize.sm))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(tint)
                        .symbolEffect(
                            .pulse,
                            options: .repeating,
                            isActive: item.severity == "critical"
                        )
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.conflictTypeDisplay ?? item.conflictType)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(item.resourceDisplayName ?? "Recurso")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: onActionsTap) {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: Theme.IconSize.sm))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(isResolving)
        }
    }

    private var icon: String {
        switch item.severity {
        case "critical": return "exclamationmark.octagon.fill"
        case "warning":  return "exclamationmark.triangle.fill"
        case "info":     return "info.circle.fill"
        default:         return "exclamationmark.circle"
        }
    }

    private var tint: Color {
        switch item.severity {
        case "critical": return .red
        case "warning":  return .orange
        case "info":     return .blue
        default:         return .secondary
        }
    }
}

// MARK: - Alert + Modifier fileprivate

fileprivate struct ContextConflictsListAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct ContextConflictsListModifier: ViewModifier {
    @Binding var pendingConflict: ContextConflictItem?
    @Binding var isShowingDialog: Bool
    @Binding var alert: ContextConflictsListAlert?
    @Binding var isShowingAlert: Bool
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
            } message: { _ in
                Text("¿Qué hacemos con este conflicto?")
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
