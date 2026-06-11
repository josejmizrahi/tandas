import SwiftUI
import RuulCore

// MARK: - Próximo evento (R.5V.3A — bloque dedicado, fuera del Dashboard)

struct ContextDetailV2NextEventSection: View {
    let context: AppContext
    let container: DependencyContainer

    var body: some View {
        Section {
            NavigationLink {
                EventsListView(context: context, container: container)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ver próximos eventos")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.Text.primary)
                        Text("Calendario del espacio")
                            .font(.caption)
                            .foregroundStyle(Theme.Text.secondary)
                    }
                } icon: {
                    Image(systemName: "calendar")
                        .foregroundStyle(Theme.Tint.info)
                }
            }
        } header: {
            Text("Próximo evento")
        }
    }
}

// MARK: - Balance (R.5V.3A — bloque dedicado en Overview)

struct ContextDetailV2BalanceSection: View {
    let money: ContextMoneyPreview
    let context: AppContext
    let container: DependencyContainer

    var body: some View {
        Section {
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
        } header: {
            Text("Mi balance")
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

    /// Label friendly para event_type (e.g. `resource.created` → `Recurso · creado`).
    private func activityEventLabel(_ eventType: String) -> String {
        let parts = eventType.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return eventType }
        let domain = activityDomainLabel(parts[0])
        let action = parts[1]
            .replacingOccurrences(of: "_", with: " ")
        return "\(domain) · \(action)"
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
