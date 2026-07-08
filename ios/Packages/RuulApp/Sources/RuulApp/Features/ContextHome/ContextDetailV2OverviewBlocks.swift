import SwiftUI
import RuulCore

// MARK: - Eventos (R.10.E.5 — Apple Music header pattern, founder firmado 2026-06-15)
//
// Section sólo muestra DATA (próximos eventos). "Ver todos" vive como
// link trailing en el header (Apple Music / Apple News pattern), no como
// row del body. Affordances secundarias (Calendario) viven en el
// toolbar `+` Menu via descriptor.actions section=events.
//
// Empty state: row CTA "Crear el primer evento" abre CreateEventView
// directo en sheet (R.15 — antes navegaba a EventsListView: otro empty
// state + botón `+`, doble hop). Al crear, se cierra la sheet y se empuja
// el EventDetailView del evento nuevo (mismo patrón CreatedEventTarget +
// navigationDestination(item:) que EventsListView).
//
// Histórico: pre-E.5 mezclaba 2 drill rows en el body (Calendario + Ver
// todos los eventos) que contaminaban la Section con affordances. E.5
// separa data (Section) de affordances (header link + toolbar).

struct ContextDetailV2EventsSection: View {
    let descriptor: ContextDetailDescriptor
    let context: AppContext
    let container: DependencyContainer

    // R.15 — estado local para el CTA del empty state: sheet de creación +
    // push al detalle del evento recién creado.
    @State private var eventsStore: EventsStore
    @State private var isShowingCreate = false
    @State private var createdEvent: CreatedEventTarget?

    private struct CreatedEventTarget: Identifiable, Hashable {
        let id: UUID
    }

    init(descriptor: ContextDetailDescriptor, context: AppContext, container: DependencyContainer) {
        self.descriptor = descriptor
        self.context = context
        self.container = container
        _eventsStore = State(initialValue: EventsStore(rpc: container.rpc))
    }

    var body: some View {
        let d = descriptor
        Section {
            if d.eventsPreview.isEmpty {
                Button {
                    isShowingCreate = true
                } label: {
                    Label("Crear el primer evento", systemImage: "calendar.badge.plus")
                        .foregroundStyle(Theme.Tint.primary)
                }
                .sheet(isPresented: $isShowingCreate) {
                    CreateEventView(context: context, store: eventsStore, container: container, onCreated: { id in
                        isShowingCreate = false
                        createdEvent = CreatedEventTarget(id: id)
                    })
                }
                // Anclado al row visible: el push sólo se dispara desde la
                // sheet que ese mismo row presentó, así que el row sigue
                // instalado cuando `createdEvent` se setea.
                .navigationDestination(item: $createdEvent) { created in
                    EventDetailView(eventId: created.id, context: context, container: container)
                }
            } else {
                ForEach(d.eventsPreview.prefix(3)) { ev in
                    NavigationLink {
                        EventDetailView(eventId: ev.eventId, context: context, container: container)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ev.title)
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(Theme.Text.primary)
                                    .lineLimit(1)
                                if let starts = ev.startsAt {
                                    Text(starts.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(Theme.Text.tertiary)
                                }
                            }
                        } icon: {
                            Image(systemName: "calendar.badge.clock")
                                .foregroundStyle(Theme.Tint.primary)
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Próximos eventos")
                Spacer()
                if !d.eventsPreview.isEmpty {
                    NavigationLink {
                        EventsListView(context: context, container: container)
                    } label: {
                        HStack(spacing: 2) {
                            Text("Ver todos")
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(Theme.Tint.primary)
                    }
                    .font(.subheadline.weight(.regular))
                }
            }
            .textCase(nil)
        }
    }
}

// MARK: - Activity

struct ContextDetailV2ActivitySection: View {
    let events: [ActivityPreviewEvent]
    let context: AppContext
    let container: DependencyContainer

    // R.10.E.5 — Apple Music header pattern. Section sólo muestra DATA
    // (3 actividades más recientes). "Ver todo" vive en el header trailing,
    // no como row del body.

    var body: some View {
        Section {
            ForEach(events.prefix(3)) { ev in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activityEventLabel(ev.eventType))
                            .font(.callout)
                            .foregroundStyle(Theme.Text.primary)
                        if let when = ev.occurredAt {
                            Text(when.formatted(.relative(presentation: .named)))
                                .font(.caption)
                                .foregroundStyle(Theme.Text.tertiary)
                        }
                    }
                } icon: {
                    Image(systemName: activityEventIcon(ev.eventType))
                        .foregroundStyle(activityEventTint(ev.eventType))
                }
            }
        } header: {
            HStack {
                Text("Actividad reciente")
                Spacer()
                NavigationLink {
                    ActivityFeedView(context: context, container: container)
                } label: {
                    HStack(spacing: 2) {
                        Text("Ver todo")
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(Theme.Tint.primary)
                }
                .font(.subheadline.weight(.regular))
            }
            .textCase(nil)
        }
    }

    /// SF Symbol consistente por familia de event_type. Fallback a `bolt.circle`.
    private func activityEventIcon(_ eventType: String) -> String {
        if eventType.hasPrefix("resource.")  { return "shippingbox.fill" }
        if eventType.hasPrefix("event.")     { return "calendar" }
        if eventType.hasPrefix("decision.")  { return "checkmark.bubble.fill" }
        if eventType.hasPrefix("obligation.") || eventType.hasPrefix("fine.") { return "doc.text.fill" }
        if eventType.hasPrefix("expense.")   { return "dollarsign.circle.fill" }
        if eventType.hasPrefix("settlement.") { return "creditcard.fill" }
        if eventType.hasPrefix("reservation.") { return "calendar.badge.clock" }
        if eventType.hasPrefix("document.")  { return "doc.text" }
        if eventType.hasPrefix("right.")     { return "key.fill" }
        if eventType.hasPrefix("invite.") || eventType.hasPrefix("membership.") { return "person.badge.plus" }
        if eventType.hasPrefix("context.")   { return "rectangle.split.2x1.fill" }
        if eventType.hasPrefix("rule.")      { return "ruler.fill" }
        if eventType.hasPrefix("conflict.") || eventType.contains(".conflict_") { return "exclamationmark.triangle.fill" }
        if eventType.hasPrefix("split.")     { return "divide.circle.fill" }
        if eventType.hasPrefix("subscription.") { return "bookmark.fill" }
        if eventType.hasPrefix("governance.") { return "checkmark.shield.fill" }
        return "bolt.circle"
    }

    /// Tint semántico para activity icon: dinero/conflict/governance diferenciados.
    private func activityEventTint(_ eventType: String) -> Color {
        if eventType.hasPrefix("expense.") || eventType.hasPrefix("settlement.") ||
           eventType.hasPrefix("split.") || eventType.contains("fine.") { return Theme.Tint.success }
        if eventType.hasPrefix("conflict.") || eventType.contains(".conflict_") {
            return Theme.Tint.warning
        }
        if eventType.hasPrefix("decision.") || eventType.hasPrefix("governance.") {
            return .purple
        }
        if eventType.hasPrefix("rule.") { return Theme.Tint.info }
        return Theme.Tint.primary
    }

    /// Fase 9.2 (founder feedback 2026-06-14) — antes mostraba "Decisión ·
    /// vote cast" (raw action). Ahora copia humana matching el `typeLabel`
    /// canónico de ActivityEvent. Cero raw underscores en pantalla.
    private func activityEventLabel(_ eventType: String) -> String {
        switch eventType {
        // Decisiones
        case "decision.created":                                  return "Nueva decisión"
        case "decision.vote_cast", "vote.cast":                   return "Nuevo voto"
        case "decision.option_added", "decision.option_created":  return "Opción agregada"
        case "decision.closed":                                   return "Decisión cerrada"
        case "decision.approved":                                 return "Decisión aprobada"
        case "decision.rejected":                                 return "Decisión rechazada"
        case "decision.executed":                                 return "Decisión ejecutada"
        // Eventos
        case "event.created", "calendar_event.created":           return "Nuevo evento"
        case "event.rsvp", "event.rsvp_updated":                  return "RSVP actualizado"
        case "event.checked_in":                                  return "Check-in"
        case "event.participation_cancelled":                     return "Asistencia cancelada"
        case "event.closed", "calendar_event.closed":             return "Evento cerrado"
        case "event.participant_plus_updated",
             "event.participant_plus_one_updated":                return "Acompañantes actualizados"
        case "event.participants_added":                          return "Participantes agregados"
        case "event.participants_removed":                        return "Participantes removidos"
        case "event.guest_added":                                 return "Invitado agregado"
        case "event.guest_removed":                               return "Invitado removido"
        // Recursos / derechos
        case "resource.created":                                  return "Nuevo recurso"
        case "resource.updated":                                  return "Recurso actualizado"
        case "resource.archived":                                 return "Recurso archivado"
        case "resource.transferred":                              return "Recurso transferido"
        case "right.granted":                                     return "Derecho otorgado"
        case "right.revoked":                                     return "Derecho revocado"
        // Reservaciones
        case "reservation.requested":                             return "Nueva reservación"
        case "reservation.approved":                              return "Reservación aprobada"
        case "reservation.confirmed":                             return "Reservación confirmada"
        case "reservation.cancelled":                             return "Reservación cancelada"
        case "reservation.conflict_detected":                     return "Conflicto de reservación"
        case "reservation.conflict_resolved":                     return "Conflicto resuelto"
        // Dinero
        case "expense.recorded":                                  return "Nuevo gasto"
        case "fine.created":                                      return "Multa generada"
        case "split.generated":                                   return "Reparto generado"
        case "game_result.recorded":                              return "Resultado de juego"
        case "settlement.generated":                              return "Liquidación generada"
        case "settlement.paid":                                   return "Pago de liquidación"
        case "obligation.created":                                return "Nuevo compromiso"
        case "obligation.completed", "obligation.fulfilled":      return "Compromiso cumplido"
        case "obligation.settled", "obligation.paid":             return "Compromiso pagado"
        case "obligation.cancelled":                              return "Compromiso cancelado"
        case "obligation.disputed":                               return "Compromiso disputado"
        case "obligation.forgiven":                               return "Compromiso perdonado"
        // Membresía / grupo
        case "membership.joined", "member.joined":                return "Se unió al grupo"
        case "membership.invited", "member.invited":              return "Miembro invitado"
        case "membership.removed", "member.removed":              return "Miembro removido"
        case "membership.left", "member.left":                    return "Salió del grupo"
        case "membership.state_changed":                          return "Estado del miembro cambió"
        case "invite.created":                                    return "Invitación creada"
        case "invite.revoked":                                    return "Invitación cancelada"
        case "context.created":                                   return "Grupo creado"
        case "context.updated":                                   return "Grupo actualizado"
        case "context.archived":                                  return "Grupo archivado"
        // Documentos / reglas / suscripciones
        case "document.created", "document.registered":           return "Nuevo documento"
        case "document.archived":                                 return "Documento archivado"
        case "rule.created":                                      return "Nueva regla"
        case "rule.evaluated":                                    return "Regla evaluada"
        case "rule.archived":                                     return "Regla archivada"
        case "subscription.created", "subscription.activated":    return "Nueva suscripción"
        case "trust.added":                                       return "Confianza declarada"
        case "trust.removed":                                     return "Confianza retirada"
        default:
            // Fallback derivado: "domain.something_special" → "Domain · Something special"
            let parts = eventType.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return eventType }
            let domain = activityDomainLabel(parts[0])
            let action = parts[1]
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
            return "\(domain) · \(action)"
        }
    }

    private func activityDomainLabel(_ domain: String) -> String {
        switch domain {
        case "resource":     return "Recurso"
        case "event":        return "Evento"
        case "decision":     return "Decisión"
        case "obligation":   return "Compromiso"
        case "fine":         return "Multa"
        case "expense":      return "Gasto"
        case "settlement":   return "Liquidación"
        case "reservation":  return "Reserva"
        case "document":     return "Documento"
        case "right":        return "Derecho"
        case "invite":       return "Invitación"
        case "membership":   return "Membresía"
        case "context":      return "Grupo"
        case "rule":         return "Regla"
        case "split":        return "Split"
        case "subscription": return "Suscripción"
        case "governance":   return "Administración"
        default:             return domain.capitalized
        }
    }
}
