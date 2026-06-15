import SwiftUI
import RuulCore

// MARK: - Events tab (R.5Z.fix.CONTEXT.TABS)

struct ContextDetailV2EventsTab: View {
    let descriptor: ContextDetailDescriptor
    let context: AppContext
    let container: DependencyContainer
    @Binding var pushedActionDestination: ContextDetailViewV2.QuickActionPush?

    var body: some View {
        let d = descriptor
        // Quick actions arriba: crear evento + ver calendario.
        Section {
            Button {
                pushedActionDestination = .events
            } label: {
                Label("Ver todos los eventos", systemImage: "list.bullet.rectangle")
            }
            NavigationLink {
                ContextCalendarView(context: context, container: container)
            } label: {
                Label("Calendario", systemImage: "calendar")
            }
        } header: {
            Text("Eventos del espacio")
        } footer: {
            Text("Los gastos del evento se reparten entre los confirmados con sus partes.")
        }

        // Eventos próximos del descriptor preview.
        if !d.eventsPreview.isEmpty {
            Section {
                ForEach(d.eventsPreview) { ev in
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
                                        .foregroundStyle(Theme.Text.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "calendar.badge.clock")
                                .foregroundStyle(Theme.Tint.primary)
                        }
                    }
                }
            } header: {
                Text("Próximos")
            }
        } else {
            Section {
                Label("Sin eventos próximos", systemImage: "calendar")
                    .foregroundStyle(Theme.Text.secondary)
            }
        }

        // Fase 9 (audit 2026-06-14) — extensión del fix Issue 1 founder.
        if !d.childContextsPreview.isEmpty {
            Section {
                ForEach(d.childContextsPreview) { child in
                    let childContext = AppContext(
                        id: child.id,
                        kind: ActorKind(rawValue: child.actorKind) ?? .collective,
                        subtype: child.actorSubtype ?? "other",
                        displayName: child.displayName
                    )
                    NavigationLink {
                        ContextDetailViewV2(
                            contextId: child.id,
                            context: childContext,
                            container: container
                        )
                    } label: {
                        Label(child.displayName, systemImage: childContext.symbolName)
                    }
                }
            } header: {
                Text("Eventos en subespacios (\(d.childContextsPreview.count))")
            } footer: {
                Text("Cada subespacio tiene su propio calendario.")
            }
        }
    }
}

// MARK: - Governance tab (R.5Z.fix.CONTEXT.TABS)
//
// Tab que un grupo de amigos necesita para organizarse: decisiones
// abiertas para votar + reglas vigentes + atajo para crear propuesta.

struct ContextDetailV2GovernanceTab: View {
    let descriptor: ContextDetailDescriptor
    let context: AppContext
    let container: DependencyContainer
    @Binding var pushedActionDestination: ContextDetailViewV2.QuickActionPush?

    var body: some View {
        let d = descriptor
        Section {
            Button {
                pushedActionDestination = .decisions
            } label: {
                Label("Ver todas las decisiones", systemImage: "checkmark.bubble.fill")
            }
            Button {
                pushedActionDestination = .rules
            } label: {
                Label("Ver reglas del grupo", systemImage: "ruler.fill")
            }
        } header: {
            Text("Gobierno del espacio")
        } footer: {
            Text("Decidan juntos: votos para temas grupales, reglas para convivir bien.")
        }

        // Decisiones abiertas del descriptor preview.
        if !d.decisionsPreview.isEmpty {
            Section {
                ForEach(d.decisionsPreview) { dec in
                    NavigationLink {
                        DecisionDetailView(decisionId: dec.decisionId, context: context, container: container)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dec.title)
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(Theme.Text.primary)
                                    .lineLimit(1)
                                Text("Decisión abierta · tu voto cuenta")
                                    .font(.caption)
                                    .foregroundStyle(Theme.Tint.warning)
                            }
                        } icon: {
                            Image(systemName: "checkmark.bubble.fill")
                                .foregroundStyle(Theme.Tint.warning)
                        }
                    }
                }
            } header: {
                Text("Decisiones abiertas")
            }
        } else {
            Section {
                Label("Sin decisiones abiertas", systemImage: "checkmark.circle")
                    .foregroundStyle(Theme.Text.secondary)
            } header: {
                Text("Decisiones abiertas")
            }
        }
    }
}

// MARK: - People tab
//
// P0 fix 2026-06-08: removidos NavigationLinks redundantes en member rows
// y role rows — todos pusheaban a la MISMA `MembersListView`. Member rows
// ahora pasivos (preview info), UN solo CTA al final pushea la lista
// completa con drill-down a MemberDetailView. Roles también pasivos.

struct ContextDetailV2PeopleTab: View {
    let descriptor: ContextDetailDescriptor
    let context: AppContext
    let container: DependencyContainer

    var body: some View {
        let d = descriptor
        Section {
            if d.membersPreview.isEmpty {
                Label("Sin miembros para mostrar", systemImage: "person.2")
                    .foregroundStyle(Theme.Text.secondary)
            } else {
                ForEach(d.membersPreview) { m in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(Theme.Tint.primary.opacity(0.15))
                            .frame(width: 36, height: 36)
                            .overlay(
                                Text(m.displayName.first.map { String($0) } ?? "?")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(Theme.Tint.primary)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.displayName)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(Theme.Text.primary)
                            Text(membershipTypeLabel(m.membershipType))
                                .font(.caption)
                                .foregroundStyle(Theme.Text.secondary)
                        }
                        Spacer()
                    }
                }
                NavigationLink {
                    MembersListView(context: context, container: container)
                } label: {
                    Label(
                        d.metrics.memberCount > d.membersPreview.count
                            ? "Ver todos los miembros (\(d.metrics.memberCount))"
                            : "Ver detalle de miembros",
                        systemImage: "person.3.fill"
                    )
                }
            }
        } header: {
            Text("Miembros (\(d.metrics.memberCount))")
        }

        if !d.roles.isEmpty {
            Section {
                ForEach(d.roles) { role in
                    LabeledContent {
                        Text("\(role.memberCount)")
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Theme.Text.primary)
                    } label: {
                        Label(role.displayName, systemImage: roleIcon(role.roleKey))
                    }
                }
            } header: {
                Text("Roles")
            } footer: {
                Text("Los roles se asignan desde el detalle de cada miembro.")
            }
        }

        // Issue 1 founder (audit 2026-06-14) — cuando el espacio tiene
        // subespacios, antes el usuario veía solo los miembros directos sin
        // saber que existían más en los hijos. Ahora mostramos una sección
        // con cada subespacio + su count de miembros, y un NavigationLink al
        // ContextDetailV2 del hijo para ver su gente.
        if !d.childContextsPreview.isEmpty {
            Section {
                ForEach(d.childContextsPreview) { child in
                    let childContext = AppContext(
                        id: child.id,
                        kind: ActorKind(rawValue: child.actorKind) ?? .collective,
                        subtype: child.actorSubtype ?? "other",
                        displayName: child.displayName
                    )
                    NavigationLink {
                        ContextDetailViewV2(
                            contextId: child.id,
                            context: childContext,
                            container: container
                        )
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: childContext.symbolName)
                                .foregroundStyle(Theme.Tint.primary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(child.displayName)
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(Theme.Text.primary)
                                Text("Tocar para ver sus miembros")
                                    .font(.caption)
                                    .foregroundStyle(Theme.Text.secondary)
                            }
                            Spacer()
                        }
                    }
                }
            } header: {
                Text("Subespacios (\(d.childContextsPreview.count))")
            } footer: {
                Text("Cada subespacio tiene sus propios miembros e invitaciones. Toca uno para verlos.")
            }
        }
    }

    /// Friendly label para membership_type del descriptor.
    private func membershipTypeLabel(_ type: String) -> String {
        switch type {
        case "member":   return "Miembro"
        case "admin":    return "Administrador"
        case "founder":  return "Fundador"
        case "guest":    return "Invitado"
        case "viewer":   return "Observador"
        default:         return type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// SF Symbol per role_key. Heurística por keyword.
    private func roleIcon(_ roleKey: String) -> String {
        let k = roleKey.lowercased()
        if k.contains("founder") || k.contains("owner") { return "crown.fill" }
        if k.contains("admin") { return "person.badge.key.fill" }
        if k.contains("manager") || k.contains("custodian") { return "key.fill" }
        if k.contains("guest") || k.contains("viewer") { return "eye.fill" }
        if k.contains("treasurer") || k.contains("financ") { return "creditcard.fill" }
        return "person.badge.shield.checkmark.fill"
    }
}

// MARK: - Resources tab

struct ContextDetailV2ResourcesTab: View {
    let descriptor: ContextDetailDescriptor
    let context: AppContext
    let container: DependencyContainer

    var body: some View {
        let d = descriptor
        resourcesContent(d)
        // Fase 9 (audit 2026-06-14) — extensión del fix Issue 1 founder.
        if !d.childContextsPreview.isEmpty {
            Section {
                ForEach(d.childContextsPreview) { child in
                    let childContext = AppContext(
                        id: child.id,
                        kind: ActorKind(rawValue: child.actorKind) ?? .collective,
                        subtype: child.actorSubtype ?? "other",
                        displayName: child.displayName
                    )
                    NavigationLink {
                        ContextDetailViewV2(
                            contextId: child.id,
                            context: childContext,
                            container: container
                        )
                    } label: {
                        Label(child.displayName, systemImage: childContext.symbolName)
                    }
                }
            } header: {
                Text("Recursos en subespacios (\(d.childContextsPreview.count))")
            } footer: {
                Text("Cada subespacio tiene sus propios recursos.")
            }
        }
    }

    @ViewBuilder
    private func resourcesContent(_ d: ContextDetailDescriptor) -> some View {
        if d.resourcesPreview.isEmpty {
            Section {
                Label("Sin recursos en este contexto", systemImage: "shippingbox")
                    .foregroundStyle(Theme.Text.secondary)
            } header: {
                Text("Recursos")
            } footer: {
                Text("Crea un recurso desde el botón ＋ del toolbar del espacio.")
            }
        } else {
            // R.5A.B.0 class catalog (founder-seeded 17 classes). Header label
            // user-friendly + icon de SF Symbols por class.
            let byClass = Dictionary(grouping: d.resourcesPreview) { $0.classKey ?? "generic" }
            ForEach(byClass.keys.sorted(), id: \.self) { classKey in
                if let items = byClass[classKey] {
                    Section {
                        ForEach(items) { r in
                            NavigationLink {
                                ResourceDetailViewV2(resourceId: r.resourceId, context: context, container: container)
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(r.displayName)
                                            .font(.callout.weight(.medium))
                                            .foregroundStyle(Theme.Text.primary)
                                            .lineLimit(1)
                                        if let sub = r.subtypeKey {
                                            Text(sub.replacingOccurrences(of: "_", with: " ").capitalized)
                                                .font(.caption)
                                                .foregroundStyle(Theme.Text.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                } icon: {
                                    Image(systemName: resourceClassIcon(r.classKey ?? "generic"))
                                        .foregroundStyle(Theme.Tint.primary)
                                }
                            }
                        }
                    } header: {
                        Label(
                            resourceClassLabel(classKey),
                            systemImage: resourceClassIcon(classKey)
                        )
                    }
                }
            }
        }
    }

    /// SF Symbol por R.5A.B.0 class_key (17 classes founder-seeded).
    private func resourceClassIcon(_ classKey: String) -> String {
        switch classKey {
        case "real_estate":    return "house.fill"
        case "vehicle":        return "car.fill"
        case "equipment":      return "wrench.and.screwdriver.fill"
        case "financial":      return "banknote.fill"
        case "document":       return "doc.text.fill"
        case "event":          return "calendar"
        case "service":        return "bag.fill"
        case "agreement":      return "doc.plaintext.fill"
        case "digital_asset":  return "externaldrive.fill"
        case "right":          return "key.fill"
        case "membership":     return "person.crop.circle.fill"
        case "space":          return "square.split.bottomrightquarter.fill"
        case "money":          return "dollarsign.circle.fill"
        case "obligation":     return "doc.text.below.ecg.fill"
        case "decision":       return "checkmark.bubble.fill"
        case "rule":           return "ruler.fill"
        case "generic":        return "shippingbox.fill"
        default:               return "shippingbox.fill"
        }
    }

    /// Label friendly por class_key.
    private func resourceClassLabel(_ classKey: String) -> String {
        switch classKey {
        case "real_estate":    return "Inmuebles"
        case "vehicle":        return "Vehículos"
        case "equipment":      return "Equipo"
        case "financial":      return "Financiero"
        case "document":       return "Documentos"
        case "event":          return "Eventos"
        case "service":        return "Servicios"
        case "agreement":      return "Acuerdos"
        case "digital_asset":  return "Activos digitales"
        case "right":          return "Derechos"
        case "membership":     return "Membresías"
        case "space":          return "Espacios"
        case "money":          return "Dinero"
        case "obligation":     return "Compromisos"
        case "decision":       return "Decisiones"
        case "rule":           return "Reglas"
        case "generic":        return "Generales"
        default:               return classKey.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
