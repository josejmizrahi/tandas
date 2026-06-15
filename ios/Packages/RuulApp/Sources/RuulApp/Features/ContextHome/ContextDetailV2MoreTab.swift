import SwiftUI
import RuulCore

// MARK: - More tab

struct ContextDetailV2MoreTab: View {
    let descriptor: ContextDetailDescriptor
    /// Section keys del tab "Más" (`Tab.more.sectionKeys` del padre).
    let moreSectionKeys: Set<String>
    let context: AppContext
    let container: DependencyContainer

    // R.10.E.2 D3 (founder firmado 2026-06-14) — la lista expandida de
    // invitaciones (full row + envelope frame + monospaced code + usage +
    // expiry + swipe-to-revoke + confirmationDialog) ocupaba demasiado
    // espacio. Ahora se colapsa a UN row con conteo, drill-down a
    // `InviteMembersView` donde vive el flujo de generación + revoke
    // (UN solo lugar para gestionar códigos del espacio).

    var body: some View {
        let d = descriptor
        let activeCount = d.pendingInvitationsPreview.count
        if activeCount > 0 {
            Section {
                NavigationLink {
                    InviteMembersView(
                        context: context,
                        store: MembersStore(rpc: container.rpc),
                        container: container
                    )
                } label: {
                    Label {
                        HStack {
                            Text("Invitaciones activas")
                                .foregroundStyle(Theme.Text.primary)
                            Spacer()
                            Text("\(activeCount)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(Theme.Text.secondary)
                        }
                    } icon: {
                        Image(systemName: "envelope.fill")
                            .foregroundStyle(Theme.Tint.info)
                    }
                }
            }
        }

        let moreSections = d.sections.filter {
            $0.visible && moreSectionKeys.contains($0.sectionKey)
        }
        Section {
            if moreSections.isEmpty {
                Label("Sin más secciones", systemImage: "ellipsis.circle")
                    .foregroundStyle(Theme.Text.secondary)
            } else {
                ForEach(moreSections) { section in
                    NavigationLink {
                        moreSectionDestination(section.sectionKey)
                    } label: {
                        Label(section.displayName, systemImage: section.icon ?? "circle")
                    }
                }
            }
        } header: {
            Text("Secciones")
        }

        // 7.C.5 (audit 2026-06-14) — `ContextTreeView` antes era código muerto
        // (solo se autoreferenciaba en Preview). Lo cableamos aquí como link
        // explícito para que el usuario vea la jerarquía completa del espacio
        // cuando tiene subespacios. El descriptor ya trae childContextsPreview.
        if !d.childContextsPreview.isEmpty {
            Section {
                NavigationLink {
                    ContextTreeView(rootContext: context, container: container)
                } label: {
                    Label("Ver estructura del espacio", systemImage: "list.bullet.indent")
                }
            } footer: {
                Text("Muestra todos los subespacios anidados bajo este espacio.")
            }
        }

        // R.10.E.2 D4 (founder firmado 2026-06-14) — Section "Mis permisos"
        // eliminada. Los strings raw (context.invite, context.manage, etc.)
        // son leakage técnico: los permisos ya gatean la UI implícitamente.
        // Para debug viven en ContextSettingsView.
    }

    @ViewBuilder
    private func moreSectionDestination(_ sectionKey: String) -> some View {
        switch sectionKey {
        case "calendar":   ContextCalendarView(context: context, container: container)
        case "governance": DecisionsListView(context: context, container: container)
        case "documents":  ContextDocumentsListView(context: context, container: container)
        case "activity":   ActivityFeedView(context: context, container: container)
        case "settings":   ContextSettingsView(context: context, container: container)
        default:           ActivityFeedView(context: context, container: container)
        }
    }

}
