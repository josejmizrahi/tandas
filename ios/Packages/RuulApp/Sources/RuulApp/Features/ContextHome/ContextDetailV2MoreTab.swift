import SwiftUI
import RuulCore

// MARK: - More tab

struct ContextDetailV2MoreTab: View {
    let descriptor: ContextDetailDescriptor
    /// Section keys del tab "Más" (`Tab.more.sectionKeys` del padre).
    let moreSectionKeys: Set<String>
    let context: AppContext
    let container: DependencyContainer

    // P0.2 — revocar códigos de invitación. El descriptor se recarga con el
    // ciclo normal del padre; aquí ocultamos el row revocado al instante.
    @State private var revokedInviteIds: Set<UUID> = []
    @State private var inviteToRevoke: ContextInvitePreview?
    @State private var revokeRunner = ActionRunner()

    private var canRevokeInvites: Bool {
        descriptor.permissions.contains("context.invite")
    }

    var body: some View {
        let d = descriptor
        let activeInvites = d.pendingInvitationsPreview.filter { !revokedInviteIds.contains($0.inviteId) }
        if !activeInvites.isEmpty {
            Section {
                ForEach(activeInvites) { inv in
                    HStack(spacing: 12) {
                        Image(systemName: "envelope.fill")
                            .foregroundStyle(Theme.Tint.info)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(inv.code)
                                .font(.system(.callout, design: .monospaced).weight(.semibold))
                                .foregroundStyle(Theme.Text.primary)
                            Text(inviteUsageLabel(inv))
                                .font(.caption2)
                                .foregroundStyle(Theme.Text.tertiary)
                        }
                        Spacer()
                        if let exp = inv.expiresAt {
                            Text(exp.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption2)
                                .foregroundStyle(Theme.Text.tertiary)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        if canRevokeInvites {
                            Button(role: .destructive) {
                                inviteToRevoke = inv
                            } label: {
                                Label("Revocar", systemImage: "xmark.circle")
                            }
                        }
                    }
                }
            } header: {
                Text("Invitaciones activas (\(activeInvites.count))")
            } footer: {
                if canRevokeInvites {
                    Text("Desliza un código para revocarlo. Un código revocado deja de funcionar al instante.")
                }
            }
            .confirmationDialog(
                "¿Revocar el código \(inviteToRevoke?.code ?? "")?",
                isPresented: Binding(
                    get: { inviteToRevoke != nil },
                    set: { if !$0 { inviteToRevoke = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Revocar código", role: .destructive) {
                    guard let invite = inviteToRevoke else { return }
                    inviteToRevoke = nil
                    Task {
                        let ok = await revokeRunner.run {
                            try await container.rpc.revokeInvite(inviteId: invite.inviteId)
                        }
                        if ok { revokedInviteIds.insert(invite.inviteId) }
                    }
                }
                Button("Cancelar", role: .cancel) { inviteToRevoke = nil }
            } message: {
                Text("Nadie podrá unirse con este código. Los miembros que ya entraron no se ven afectados.")
            }
            .actionErrorAlert(revokeRunner)
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

        if !d.permissions.isEmpty {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(d.permissions, id: \.self) { p in
                            chipBadge(p, tint: .purple)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } header: {
                Text("Mis permisos (\(d.permissions.count))")
            }
        }
    }

    private func inviteUsageLabel(_ inv: ContextInvitePreview) -> String {
        if let max = inv.maxUses {
            return "\(inv.usedCount) / \(max) usos"
        }
        return "\(inv.usedCount) usos · ilimitado"
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

    // MARK: - Chips (helper compartido)

    @ViewBuilder
    private func chipBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
    }
}
