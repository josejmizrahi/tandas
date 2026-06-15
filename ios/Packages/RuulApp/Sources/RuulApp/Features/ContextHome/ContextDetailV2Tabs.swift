import SwiftUI
import RuulCore

// MARK: - Governance tab (R.10.E.4 — consolidado "Gobierno")
//
// R.10.E.4 (founder firmado 2026-06-14): UNA Section "Gobierno" que agrupa
// los dos surfaces de gobernanza del modelo Ruul (decisiones explícitas +
// reglas automáticas). Antes: sólo "Decisiones abiertas" cuando había, sin
// drill a reglas. Ahora: preview de decisiones abiertas + drill a la lista
// completa + drill a reglas, todo en una sola card.
//
// Doctrina: Apple HIG — una Section agrupa contenido relacionado del mismo
// dominio. Gobierno = decisiones + reglas (CLAUDE.md domain doctrine).
//
// Nota histórica: `ContextDetailV2EventsTab` (dead code post-tabs removal
// en Fase 9.6) eliminado en este slice — los eventos ahora viven en
// `ContextDetailV2EventsSection` consolidada en OverviewBlocks.swift.

struct ContextDetailV2GovernanceTab: View {
    let descriptor: ContextDetailDescriptor
    let context: AppContext
    let container: DependencyContainer

    var body: some View {
        let d = descriptor
        Section {
            // Decisiones abiertas preview (rich rows, max 3).
            ForEach(d.decisionsPreview.prefix(3)) { dec in
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

            // Drill a todas las decisiones (siempre disponible).
            NavigationLink {
                DecisionsListView(context: context, container: container)
            } label: {
                Label("Ver todas las decisiones", systemImage: "checkmark.bubble.fill")
            }

            // Drill a reglas del espacio (siempre disponible).
            NavigationLink {
                RulesListView(context: context, container: container)
            } label: {
                Label("Reglas del espacio", systemImage: "ruler.fill")
            }
        } header: {
            Text("Gobierno")
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
                Text(memberCountLabel(total: d.metrics.memberCount, roles: d.roles))
            }
        }

        // R.10.E.2 D2 (founder firmado 2026-06-14) — Section "Roles" eliminada
        // del ContextDetail. Los roles se asignan desde MemberDetailView; el
        // recuento por rol ahora vive en el footer compacto de "Miembros".
        //
        // Fase 9.7 — la sección "Subespacios" interna también está eliminada
        // (la renderiza `unifiedSections` al final de la lista).
    }

    // R.10.E.2 D2 — `membershipTypeLabel` y `roleIcon` eliminados: el
    // primero servía a rows de miembros que ya no existen (E.1 avatars row);
    // el segundo a la Section "Roles" que también desapareció en D2.

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

    /// R.10.E.2 D2 — footer compacto: "N miembros · 2 admins · 1 fundador".
    /// Compone el total + breakdown por roles con `member_count > 0`,
    /// excluyendo los plurales triviales (member/miembro genérico).
    private func memberCountLabel(total: Int, roles: [ContextRole]) -> String {
        let base = total == 1 ? "1 miembro" : "\(total) miembros"
        let breakdown = roles
            .filter { $0.memberCount > 0 }
            .filter { $0.roleKey.lowercased() != "member" }
            .sorted { $0.memberCount > $1.memberCount }
            .map { "\($0.memberCount) \(roleSummaryLabel($0))" }
        return ([base] + breakdown).joined(separator: " · ")
    }

    /// Mini-label en plural-implicit para el footer (lower-case, sin sufijo).
    private func roleSummaryLabel(_ role: ContextRole) -> String {
        let k = role.roleKey.lowercased()
        if k.contains("founder") || k.contains("owner") { return role.memberCount == 1 ? "fundador" : "fundadores" }
        if k.contains("admin") { return role.memberCount == 1 ? "admin" : "admins" }
        if k.contains("treasurer") || k.contains("financ") { return role.memberCount == 1 ? "tesorero" : "tesoreros" }
        if k.contains("guest") || k.contains("viewer") { return role.memberCount == 1 ? "invitado" : "invitados" }
        if k.contains("manager") || k.contains("custodian") { return role.memberCount == 1 ? "responsable" : "responsables" }
        return role.displayName.lowercased()
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
            // R.10.E.2 D7 (founder firmado 2026-06-14) — empty state activo:
            // CTA NavigationLink → ResourcesListView (donde vive el toolbar
            // "+" para crear el primer recurso). Antes era un row pasivo con
            // copy instructional "desde el botón ＋ del toolbar".
            Section {
                NavigationLink {
                    ResourcesListView(context: context, container: container)
                } label: {
                    Label("Crear el primer recurso", systemImage: "shippingbox.fill")
                        .foregroundStyle(Theme.Tint.primary)
                }
            } header: {
                Text("Recursos")
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
