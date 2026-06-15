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

        // R.10.E.9 (founder firmado 2026-06-15) — drills duplicados eliminados.
        // Post-E.5/E.6/E.8 las siguientes section drills ya tienen home en otras
        // surfaces:
        //   - governance → Decisiones Section header trailing "Ver todas" (E.5)
        //   - activity   → Actividad Section header trailing "Ver todo" (E.5)
        //   - settings   → Toolbar gearshape button (E.8)
        //   - estructura → Subespacios Section header trailing "Ver todos" (E.6)
        // Sólo quedan drills únicos no cubiertos en el body: calendar y documents.
        // Si filteredSections queda vacío, ocultar Section (D6 doctrine).
        let moreSections = d.sections.filter {
            $0.visible && moreSectionKeys.contains($0.sectionKey)
        }
        if !moreSections.isEmpty {
            Section {
                ForEach(moreSections) { section in
                    NavigationLink {
                        moreSectionDestination(section.sectionKey)
                    } label: {
                        Label(section.displayName, systemImage: section.icon ?? "circle")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func moreSectionDestination(_ sectionKey: String) -> some View {
        switch sectionKey {
        case "calendar":   ContextCalendarView(context: context, container: container)
        case "documents":  ContextDocumentsListView(context: context, container: container)
        default:           ContextDocumentsListView(context: context, container: container)
        }
    }

}
