import SwiftUI
import RuulCore

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

// MARK: - Recursos (R.10.E.6 — Apple Music header pattern, founder firmado 2026-06-15)
//
// Antes la Section sólo aparecía cuando descriptor.sections incluía
// "resources" como visible — para algunos contextos colectivos no
// aparecía en absoluto (founder: "EN CONTEXT DETAIL ESA FALTA ESA
// SECCION"). Ahora se renderiza siempre para contextos colectivos.
//
// Cambios E.6:
//   - UN solo Section "Recursos" (antes: 1 Section por classKey con
//     header `Label(claseDisplay, classIcon)`).
//   - Preview compacto de los primeros 5 recursos con icon por clase +
//     nombre + subtype.
//   - Header trailing "Ver todos >" → ResourcesListView (Apple Music
//     pattern, mismo que Eventos/Decisiones/Actividad).
//   - Empty state CTA "Crear el primer recurso" preservado (D7).
//   - Siempre renderizado (sin gate de visibleKeys).

struct ContextDetailV2ResourcesSection: View {
    let descriptor: ContextDetailDescriptor
    let context: AppContext
    let container: DependencyContainer

    var body: some View {
        let d = descriptor
        Section {
            if d.resourcesPreview.isEmpty {
                NavigationLink {
                    ResourcesListView(context: context, container: container)
                } label: {
                    Label("Crear el primer recurso", systemImage: "shippingbox.fill")
                        .foregroundStyle(Theme.Tint.primary)
                }
            } else {
                ForEach(d.resourcesPreview.prefix(5)) { r in
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
                            Image(systemName: Self.resourceClassIcon(r.classKey ?? "generic"))
                                .foregroundStyle(Theme.Tint.primary)
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Recursos")
                Spacer()
                if !d.resourcesPreview.isEmpty {
                    NavigationLink {
                        ResourcesListView(context: context, container: container)
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

    /// SF Symbol por R.5A.B.0 class_key (17 classes founder-seeded).
    static func resourceClassIcon(_ classKey: String) -> String {
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
}
