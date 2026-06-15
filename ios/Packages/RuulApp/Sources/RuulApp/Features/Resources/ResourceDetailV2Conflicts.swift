import SwiftUI
import RuulCore

/// R.10.A — Conflicts section + modifier (code move, zero behavior change).
///
/// Doctrina: R.5V native-first · "Section is the card".
/// Mueve `conflictsSection` (378–425), `ConflictsModifier` (1481–1516),
/// `ConflictResolveAlert` (1641–1645) y helpers de copy (1352–1466 salvo
/// `resolveConflict` que sigue en main por dependencias de @State).

struct ResourceDetailV2ConflictsSection: View {
    let list: ResourceConflictList
    let isResolving: Bool
    @Binding var pendingConflict: ResourceConflict?
    @Binding var isShowingDialog: Bool

    var body: some View {
        let critical = list.items.filter(\.isCritical).count
        Section {
            ForEach(list.items.prefix(4)) { item in
                Button {
                    guard !isResolving else { return }
                    pendingConflict = item
                    isShowingDialog = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: ResourceDetailV2ConflictsCopy.severityIcon(item.severity))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(ResourceDetailV2ConflictsCopy.severityTint(item.severity))
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
                            Text(ResourceDetailV2ConflictsCopy.rowSubtitle(item))
                                .font(.caption)
                                .foregroundStyle(Theme.Text.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                }
                .disabled(isResolving)
            }
            if list.items.count > 4 {
                Text("+ \(list.items.count - 4) más")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
            }
        } header: {
            Text("Conflictos abiertos")
        } footer: {
            Text(ResourceDetailV2ConflictsCopy.subtitle(open: list.openCount, critical: critical))
        }
    }
}

/// Helpers de copy/iconografía. Snapshot estático puro.
enum ResourceDetailV2ConflictsCopy {
    static func subtitle(open: Int, critical: Int) -> String {
        if critical > 0 {
            return critical == open
                ? "\(critical) crítico\(critical == 1 ? "" : "s")"
                : "\(critical) crítico\(critical == 1 ? "" : "s") · \(open) abierto\(open == 1 ? "" : "s")"
        }
        return "\(open) abierto\(open == 1 ? "" : "s")"
    }

    static func rowSubtitle(_ c: ResourceConflict) -> String {
        if c.sourceDecisionId != nil {
            return "Escalado a decisión"
        }
        switch c.sourceType {
        case "reservation_conflict", "reservation_pair":
            return c.category?.capitalized ?? "Conflicto de reservación"
        case "reservation":
            return "Reserva afectada"
        default:
            return c.category?.capitalized ?? c.severity.capitalized
        }
    }

    static func severityIcon(_ severity: String) -> String {
        switch severity {
        case "critical": return "exclamationmark.octagon.fill"
        case "warning":  return "exclamationmark.triangle.fill"
        case "info":     return "info.circle.fill"
        default:         return "exclamationmark.circle"
        }
    }

    static func severityTint(_ severity: String) -> Color {
        switch severity {
        case "critical": return Theme.Tint.critical
        case "warning":  return Theme.Tint.warning
        case "info":     return Theme.Tint.info
        default:         return Theme.Text.secondary
        }
    }

    static func dialogMessage(_ c: ResourceConflict) -> String {
        let action = c.recommendedActionKey ?? "resolve_resource_conflict"
        let recommended: String
        switch action {
        case "escalate_to_decision":
            recommended = "Recomendado: escalar a decisión."
        case "resolve_reservation_conflict", "resolve_resource_conflict":
            recommended = "Recomendado: resolver manualmente."
        default:
            recommended = ""
        }
        return ["¿Qué hacemos con este conflicto?", recommended]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    static func resolveSuccessTitle(_ kind: ResolveResourceConflictKind) -> String {
        switch kind {
        case .manualResolution: return "Resuelto"
        case .escalate:         return "Escalado"
        case .dismiss:          return "Descartado"
        }
    }

    static func resolveSuccessMessage(_ kind: ResolveResourceConflictKind, result: ResolveResourceConflictResult) -> String {
        switch kind {
        case .manualResolution:
            return "El conflicto quedó resuelto."
        case .escalate:
            if let tmpl = result.templateKey {
                return "Se creó una decisión (\(tmpl)) para resolver el conflicto."
            }
            return "Se creó una decisión para resolver el conflicto."
        case .dismiss:
            return "El conflicto fue descartado."
        }
    }
}

/// R.5B.5b — ConflictsModifier. Movido tal cual (1481–1516).
struct ResourceDetailV2ConflictsModifier: ViewModifier {
    @Binding var pendingConflict: ResourceConflict?
    @Binding var isShowingDialog: Bool
    @Binding var alert: ResourceDetailV2ConflictResolveAlert?
    @Binding var isShowingAlert: Bool
    let dialogMessage: (ResourceConflict) -> String
    let onKind: (ResourceConflict, ResolveResourceConflictKind) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                pendingConflict?.conflictTypeDisplay ?? "Conflicto",
                isPresented: $isShowingDialog,
                titleVisibility: .visible,
                presenting: pendingConflict
            ) { conflict in
                Button("Resolver manualmente") { onKind(conflict, .manualResolution) }
                Button("Escalar a decisión")  { onKind(conflict, .escalate) }
                Button("Descartar", role: .destructive) { onKind(conflict, .dismiss) }
                Button("Cancelar", role: .cancel) {}
            } message: { conflict in
                Text(dialogMessage(conflict))
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

struct ResourceDetailV2ConflictResolveAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
