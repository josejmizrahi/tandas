import SwiftUI
import RuulCore

/// V2-G8 sub-slice 2 — "¿Por qué pasó esto?" sheet.
///
/// Pulled from any history-style row that wants to expose engine
/// provenance. Loads `system_event_engine_provenance(event_uuid)` and
/// renders one of:
/// - Loading skeleton.
/// - Engine-caused: which rule + predicate outcome + source event.
/// - Human-caused: "Esto lo registró @actor manualmente."
/// - Lookup error: short message + Reintentar.
///
/// The sheet doesn't depend on a Store — it's a fire-and-forget fetch
/// per presentation. State is local so multiple instances stay isolated.
struct WhyDidThisHappenSheet: View {
    let container: DependencyContainer
    let event: GroupEvent

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading
    @State private var provenance: SystemEventProvenance?
    @State private var errorMessage: String?

    enum Phase: Equatable {
        case loading
        case loaded
        case failed
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("¿Por qué pasó esto?")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Cerrar") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            List {
                Section { Text("Buscando origen…").redacted(reason: .placeholder) }
            }
        case .failed:
            ContentUnavailableView {
                Label("No pudimos cargar el origen", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage ?? "")
            } actions: {
                Button("Reintentar") { Task { await load() } }
            }
        case .loaded:
            if let provenance, provenance.found {
                engineCausedList(provenance)
            } else if let provenance {
                humanCausedList(provenance)
            } else {
                EmptyView()
            }
        }
    }

    // MARK: - Engine-caused

    @ViewBuilder
    private func engineCausedList(_ p: SystemEventProvenance) -> some View {
        List {
            Section("Qué pasó") {
                LabeledContent("Evento", value: event.summary ?? event.eventType)
                if let when = event.occurredAt {
                    LabeledContent("Cuándo") {
                        Text(when, format: .dateTime.day().month().year().hour().minute())
                    }
                }
            }

            Section("Lo hizo el sistema") {
                if let title = p.ruleTitle {
                    LabeledContent("Regla", value: title)
                }
                if let kind = p.consequenceKind {
                    LabeledContent("Consecuencia", value: consequenceLabel(kind))
                }
                if let target = p.targetKind {
                    LabeledContent("Aplicada a", value: targetKindLabel(target))
                }
                if let pred = p.matchedPredicate, let reason = pred.reason {
                    HStack(spacing: 6) {
                        Image(systemName: pred.passed ? "checkmark.seal.fill" : "xmark.seal.fill")
                            .foregroundStyle(pred.passed ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        Text(pred.passed ? "Condición cumplida: \(reason)" : "Condición no cumplida: \(reason)")
                            .font(.subheadline)
                    }
                }
                if p.cycleDetected == true {
                    Label("Se detectó un ciclo en la evaluación.", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
                if let depth = p.depth, depth > 0 {
                    LabeledContent("Profundidad de cadena", value: "\(depth)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let src = p.sourceEvent {
                Section("Lo disparó") {
                    LabeledContent("Evento disparador", value: src.summary ?? src.eventType)
                    if let when = src.occurredAt {
                        LabeledContent("Cuándo") {
                            Text(when, format: .dateTime.day().month().year().hour().minute())
                        }
                    }
                }
            }
        }
    }

    // MARK: - Human-caused

    @ViewBuilder
    private func humanCausedList(_ p: SystemEventProvenance) -> some View {
        List {
            Section("Qué pasó") {
                LabeledContent("Evento", value: event.summary ?? event.eventType)
                if let when = event.occurredAt {
                    LabeledContent("Cuándo") {
                        Text(when, format: .dateTime.day().month().year().hour().minute())
                    }
                }
            }

            Section("Lo hizo una persona") {
                if let actor = event.actorDisplayName {
                    Text("Lo registró \(actor) manualmente.")
                        .font(.body)
                } else {
                    Text("Lo registró un miembro manualmente.")
                        .font(.body)
                }
                if let reason = p.reason {
                    Text(reasonLabel(reason))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func reasonLabel(_ raw: String) -> String {
        switch raw {
        case "event_type_not_engine_actionable":
            return "Este tipo de evento no puede ser causado automáticamente por el engine."
        case "no_engine_origin":
            return "No encontramos una regla que haya disparado este evento."
        case "event_not_found":
            return "El evento ya no está en el registro."
        default:
            return raw
        }
    }

    /// V3-D.17 — friendly labels for the consequence kinds emitted by
    /// the D.14/D.15 dispatcher. Fall back to the raw key so future
    /// consequences ship without a code change blocking explainability.
    private func consequenceLabel(_ raw: String) -> String {
        switch raw {
        case "consequence.send_notification":   return "Enviar notificación"
        case "consequence.create_pool_charge":  return "Crear cobro al fondo"
        case "consequence.peer_obligation":     return "Crear obligación entre miembros"
        case "consequence.create_obligation":   return "Crear obligación"
        case "consequence.issue_sanction":      return "Aplicar sanción"
        case "consequence.start_vote":          return "Abrir votación"
        case "consequence.set_member_state":    return "Cambiar estado de miembro"
        case "consequence.archive_resource":    return "Archivar recurso"
        case "consequence.transfer_resource":   return "Transferir recurso"
        default:                                return raw
        }
    }

    private func targetKindLabel(_ raw: String) -> String {
        switch raw {
        case "notification":   return "Notificación"
        case "obligation":     return "Obligación"
        case "sanction":       return "Sanción"
        case "decision":       return "Decisión"
        case "membership":     return "Miembro"
        case "resource":       return "Recurso"
        default:               return raw
        }
    }

    // MARK: - Fetch

    private func load() async {
        phase = .loading
        do {
            let result = try await container.ruleEvaluationsRepository.provenance(eventUuid: event.id)
            provenance = result
            phase = .loaded
        } catch {
            errorMessage = UserFacingError.from(error).message
            phase = .failed
        }
    }
}
