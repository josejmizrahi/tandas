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

        // Fase 9.7 — "Eventos en subespacios" eliminada (redundante con
        // ChildrenSection global en `unifiedSections`).
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

    /// R.10.E.1 — máximo de avatars visibles antes del "+N" overflow.
    private let maxVisibleAvatars = 6

    var body: some View {
        let d = descriptor
        Section {
            if d.membersPreview.isEmpty {
                NavigationLink {
                    MembersListView(context: context, container: container)
                } label: {
                    Label("Invitar a la primera persona", systemImage: "person.crop.circle.badge.plus")
                        .foregroundStyle(Theme.Tint.primary)
                }
            } else {
                // R.10.E.1 — Apple Messages/FaceTime group header: avatars
                // solapados + overflow "+N" + tap a la lista completa.
                NavigationLink {
                    MembersListView(context: context, container: container)
                } label: {
                    avatarsRow(d.membersPreview, totalCount: d.metrics.memberCount)
                }
            }
        } header: {
            Text("Miembros")
        } footer: {
            if !d.membersPreview.isEmpty {
                Text(memberCountLabel(d.metrics.memberCount))
            }
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

        // Fase 9.7 — la sección "Subespacios" interna se eliminó porque
        // `unifiedSections` ya renderiza `ContextDetailV2ChildrenSection` al
        // final de la lista. Mantenerla aquí duplicaba la lista de hijos.
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

    // MARK: - R.10.E.1 helpers (avatars row)

    @ViewBuilder
    private func avatarsRow(_ members: [ContextMemberPreview], totalCount: Int) -> some View {
        let visible = Array(members.prefix(maxVisibleAvatars))
        let overflow = max(0, totalCount - visible.count)
        HStack(spacing: -12) {
            ForEach(visible) { m in
                avatarCircle(initial: m.displayName.first.map { String($0) } ?? "?")
            }
            if overflow > 0 {
                overflowCircle(overflow)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func avatarCircle(initial: String) -> some View {
        Circle()
            .fill(Theme.Tint.primary.opacity(0.15))
            .frame(width: 36, height: 36)
            .overlay {
                Text(initial)
                    .font(.subheadline.bold())
                    .foregroundStyle(Theme.Tint.primary)
            }
            .overlay {
                Circle().stroke(Color(.systemBackground), lineWidth: 2)
            }
    }

    @ViewBuilder
    private func overflowCircle(_ count: Int) -> some View {
        Circle()
            .fill(Theme.Text.secondary.opacity(0.15))
            .frame(width: 36, height: 36)
            .overlay {
                Text("+\(count)")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(Theme.Text.secondary)
            }
            .overlay {
                Circle().stroke(Color(.systemBackground), lineWidth: 2)
            }
    }

    private func memberCountLabel(_ n: Int) -> String {
        n == 1 ? "1 miembro" : "\(n) miembros"
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
        // Fase 9.7 — "Recursos en subespacios" eliminada (redundante).
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
