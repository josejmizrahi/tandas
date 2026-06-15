import SwiftUI
import RuulCore

// MARK: - Resumen rápido (Fase 9.3 — combinado próximo evento + balance)
//
// Founder feedback 2026-06-14: antes había 2 sections separadas con
// header "Próximo evento" + "Mi balance", cada una con 1 row + mucho aire
// vertical entre ellas. Consolidado en una sola section "Resumen rápido"
// para reducir spacing desperdiciado en pantallas con poca actividad.

struct ContextDetailV2QuickSummarySection: View {
    let money: ContextMoneyPreview
    let context: AppContext
    let container: DependencyContainer

    var body: some View {
        Section {
            // Balance rows (1 por moneda).
            ForEach(money.myBalanceByCurrency.sorted(by: { $0.key < $1.key }), id: \.key) { (currency, net) in
                NavigationLink {
                    MoneyHomeView(context: context, container: container)
                } label: {
                    LabeledContent {
                        Text(net.compactCurrencyLabel(currency))
                            .font(.callout.bold().monospacedDigit())
                            .foregroundStyle(net >= 0 ? Theme.Tint.success : Theme.Tint.critical)
                    } label: {
                        Label(
                            net >= 0 ? "Te deben" : "Debes",
                            systemImage: net >= 0 ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill"
                        )
                    }
                }
            }

            // Próximos eventos (link al calendario).
            NavigationLink {
                EventsListView(context: context, container: container)
            } label: {
                Label("Ver próximos eventos", systemImage: "calendar")
            }
        } header: {
            Text("Resumen rápido")
        }
    }
}

// MARK: - Próximo evento solo (cuando no hay balance — espacios sin dinero)

struct ContextDetailV2NextEventSection: View {
    let context: AppContext
    let container: DependencyContainer

    var body: some View {
        Section {
            NavigationLink {
                EventsListView(context: context, container: container)
            } label: {
                Label("Ver próximos eventos", systemImage: "calendar")
            }
        } header: {
            Text("Eventos")
        }
    }
}

// MARK: - Children (subcontextos)

struct ContextDetailV2ChildrenSection: View {
    let children: [ContextChildPreview]
    let context: AppContext
    let container: DependencyContainer

    var body: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                // R.5V.Glass.C2 — GlassEffectContainer permite morphing entre
                // los cards de hijos cuando se acercan/cruzan durante scroll.
                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 12) {
                        ForEach(children) { child in
                            childDescriptorCard(child)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .scrollTargetLayout()
                }
            }
            .scrollTargetBehavior(.viewAligned)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } header: {
            Text("Espacios dentro de \(context.displayName)")
        }
    }

    @ViewBuilder
    private func childDescriptorCard(_ child: ContextChildPreview) -> some View {
        if let target = container.contextStore.availableContexts.first(where: { $0.id == child.id }) {
            NavigationLink(value: target) {
                childDescriptorCardLabel(child)
            }
            .buttonStyle(.plain)
        } else {
            childDescriptorCardLabel(child).opacity(0.5)
        }
    }

    @ViewBuilder
    private func childDescriptorCardLabel(_ child: ContextChildPreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: childSymbolName(child))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.Tint.primary)
                    .frame(width: 40, height: 40)
                    .background(Theme.Tint.primary.opacity(0.15), in: Circle())
                Spacer()
                if child.visibility == "private" {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(Theme.Text.tertiary)
                }
            }
            Spacer(minLength: 0)
            Text(child.displayName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Theme.Text.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(childSubtypeLabel(child.actorSubtype ?? "generic"))
                .font(.caption2)
                .foregroundStyle(Theme.Text.secondary)
                .lineLimit(1)
        }
        .frame(width: 150, height: 150, alignment: .topLeading)
        .padding(14)
        // R.5V.Glass.C2 — glassEffect interactivo dentro del GlassEffectContainer
        // del childrenSection para que el morphing funcione al scroll.
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
    }

    private func childSymbolName(_ child: ContextChildPreview) -> String {
        switch child.actorSubtype {
        case "family":       return "house.fill"
        case "trip":         return "airplane"
        case "project":      return "rectangle.stack.fill"
        case "trust":        return "checkmark.shield.fill"
        case "community":    return "person.3.fill"
        case "friend_group": return "person.2.fill"
        case "company":      return "building.2.fill"
        default:             return "circle.grid.cross.fill"
        }
    }

    private func childSubtypeLabel(_ subtype: String) -> String {
        switch subtype {
        case "family":       return "Familia"
        case "community":    return "Comunidad"
        case "trip":         return "Viaje"
        case "project":      return "Proyecto"
        case "trust":        return "Fideicomiso"
        case "friend_group": return "Grupo"
        case "company":      return "Empresa"
        default:             return "Contexto"
        }
    }
}

// MARK: - Activity

struct ContextDetailV2ActivitySection: View {
    let events: [ActivityPreviewEvent]
    let context: AppContext
    let container: DependencyContainer

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
            NavigationLink {
                ActivityFeedView(context: context, container: container)
            } label: {
                Label("Ver toda la actividad", systemImage: "list.bullet")
            }
        } header: {
            Text("Actividad reciente")
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
        // Membresía / espacio
        case "membership.joined", "member.joined":                return "Se unió al espacio"
        case "membership.invited", "member.invited":              return "Miembro invitado"
        case "membership.removed", "member.removed":              return "Miembro removido"
        case "membership.left", "member.left":                    return "Salió del espacio"
        case "membership.state_changed":                          return "Estado del miembro cambió"
        case "invite.created":                                    return "Invitación creada"
        case "invite.revoked":                                    return "Invitación cancelada"
        case "context.created":                                   return "Espacio creado"
        case "context.updated":                                   return "Espacio actualizado"
        case "context.archived":                                  return "Espacio archivado"
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
        case "context":      return "Contexto"
        case "rule":         return "Regla"
        case "split":        return "Split"
        case "subscription": return "Suscripción"
        case "governance":   return "Gobierno"
        default:             return domain.capitalized
        }
    }
}
