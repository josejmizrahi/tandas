import SwiftUI
import RuulCore

/// F.5 — detalle de un miembro: roles, antigüedad y acciones de admin
/// (asignar rol admin, remover del contexto).
public struct MemberDetailView: View {
    let member: ContextMember
    let context: AppContext
    let store: MembersStore
    let myActorId: UUID?
    /// R.2R — opcional: si llega, se renderiza la sección "Compromisos" del miembro.
    let container: DependencyContainer?

    @Environment(\.dismiss) private var dismiss
    @State private var runner = ActionRunner()
    @State private var isConfirmingRemove = false
    @State private var isConfirmingLeave = false
    /// R.2R — compromisos de acción donde este miembro es deudor o acreedor.
    @State private var memberObligations: [Obligation] = []
    @State private var selectedObligationId: UUID?
    @State private var isShowingCreateObligation = false

    public init(member: ContextMember, context: AppContext, store: MembersStore, myActorId: UUID?, container: DependencyContainer? = nil) {
        self.member = member
        self.context = context
        self.store = store
        self.myActorId = myActorId
        self.container = container
    }

    private var isMe: Bool { member.actorId == myActorId }

    public var body: some View {
        // R.5V.X 2026-06-08 — Apple-native canonical Detail pattern (V.4/V.5).
        List {
            // Hero
            Section {
                HStack(spacing: 14) {
                    ActorInitialsView(name: member.displayName, size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(member.displayName)
                            .font(.title3.bold())
                            .foregroundStyle(Theme.Text.primary)
                            .lineLimit(2)
                        if let type = member.membershipType {
                            Text(membershipTypeLabel(type))
                                .font(.subheadline)
                                .foregroundStyle(Theme.Text.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if isMe {
                        Text("Tú")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.Tint.primary)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 12, leading: 4, bottom: 4, trailing: 4))
            }

            Section {
                if let joined = member.joinedAt {
                    LabeledContent {
                        Text(joined.formatted(date: .abbreviated, time: .omitted))
                    } label: {
                        Label("Se unió", systemImage: "calendar")
                    }
                }
                LabeledContent {
                    Text(member.roles.isEmpty ? "Miembro" : member.roles.joined(separator: ", "))
                        .foregroundStyle(Theme.Text.primary)
                } label: {
                    Label("Roles", systemImage: "person.text.rectangle.fill")
                }
            } header: {
                Text("Información")
            }

            // R.2R — compromisos donde participa este miembro
            if container != nil, !context.isPersonal {
                obligationsSection
            }

            // Acciones de admin
            if store.canManageMembers(in: context) && !isMe {
                Section("Administración") {
                    let assignable = assignableRoles(for: member)
                    if !assignable.isEmpty {
                        Menu {
                            ForEach(assignable, id: \.key) { role in
                                Button {
                                    Task {
                                        await runner.run {
                                            try await store.assignRole(
                                                context: context,
                                                memberActorId: member.actorId,
                                                roleKey: role.key
                                            )
                                        }
                                    }
                                } label: {
                                    Label(role.label, systemImage: role.symbol)
                                }
                            }
                        } label: {
                            Label("Asignar rol", systemImage: "person.badge.shield.checkmark")
                        }
                    }

                    Button(role: .destructive) {
                        isConfirmingRemove = true
                    } label: {
                        Label("Remover del contexto", systemImage: "person.badge.minus")
                    }
                }
            }

            // Salir (si soy yo)
            if isMe && !context.isPersonal {
                Section {
                    Button(role: .destructive) {
                        isConfirmingLeave = true
                    } label: {
                        Label("Salir de \(context.displayName)", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(member.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadObligations()
        }
        .sheet(item: Binding(get: { selectedObligationId.map { ObligationIdSheetWrapper(id: $0) } },
                              set: { selectedObligationId = $0?.id })) { wrapper in
            if let container {
                ObligationDetailView(obligationId: wrapper.id, context: context, container: container)
            }
        }
        .sheet(isPresented: $isShowingCreateObligation, onDismiss: {
            Task { await loadObligations() }
        }) {
            if let container {
                CreateObligationView(context: context, container: container, preselectedDebtorId: member.actorId)
            }
        }
        .actionErrorAlert(runner)
        .confirmationDialog(
            "¿Remover a \(member.displayName)?",
            isPresented: $isConfirmingRemove,
            titleVisibility: .visible
        ) {
            Button("Remover", role: .destructive) {
                Task {
                    let success = await runner.run {
                        try await store.removeMember(context: context, memberActorId: member.actorId, reason: nil)
                    }
                    if success { dismiss() }
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Perderá acceso a todo el contexto: eventos, recursos, dinero y actividad.")
        }
        .confirmationDialog(
            "¿Salir de \(context.displayName)?",
            isPresented: $isConfirmingLeave,
            titleVisibility: .visible
        ) {
            Button("Salir", role: .destructive) {
                Task {
                    let success = await runner.run {
                        try await store.leave(contextId: context.id)
                    }
                    if success { dismiss() }
                }
            }
            Button("Cancelar", role: .cancel) {}
        }
        .ruulCompactSheet()
    }

    // MARK: - R.2R obligations

    @ViewBuilder
    private var obligationsSection: some View {
        Section {
            if memberObligations.isEmpty {
                Label("Sin compromisos pendientes", systemImage: "checkmark.circle")
                    .foregroundStyle(Theme.Text.secondary)
            } else {
                ForEach(memberObligations.prefix(5)) { obligation in
                    Button {
                        selectedObligationId = obligation.id
                    } label: {
                        Label {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(obligation.title ?? obligation.kindLabel)
                                        .font(.callout.weight(.medium))
                                        .foregroundStyle(Theme.Text.primary)
                                        .lineLimit(1)
                                    Text(obligation.debtorActorId == member.actorId ? "Debe cumplir" : "Es acreedor")
                                        .font(.caption)
                                        .foregroundStyle(Theme.Text.secondary)
                                }
                                Spacer()
                                if let due = obligation.dueAt {
                                    Text(due.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(Theme.Text.tertiary)
                                }
                            }
                        } icon: {
                            Image(systemName: obligationSymbol(obligation.obligationKind))
                                .foregroundStyle(Theme.Tint.primary)
                        }
                    }
                }
            }
            if !isMe {
                Button {
                    isShowingCreateObligation = true
                } label: {
                    Label("Asignar compromiso", systemImage: "plus.circle.fill")
                }
            }
        } header: {
            Text("Compromisos")
        } footer: {
            Text("Compromisos de acción donde \(member.displayName) participa.")
        }
    }

    private func membershipTypeLabel(_ type: String) -> String {
        switch type {
        case "founder": return "Fundador"
        case "admin":   return "Administrador"
        case "member":  return "Miembro"
        case "guest":   return "Invitado"
        case "viewer":  return "Observador"
        default:        return type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func loadObligations() async {
        guard let container, !context.isPersonal else {
            memberObligations = []
            return
        }
        do {
            let all = try await container.rpc.listObligations(contextId: context.id)
            memberObligations = all.filter { ob in
                ob.isActionKind && ob.isOpen
                    && (ob.debtorActorId == member.actorId || ob.creditorActorId == member.actorId)
            }
        } catch {
            memberObligations = []
        }
    }

    // MARK: - F.MEMBER.2 — role assignment catalog

    /// Catálogo de roles asignables. El backend (`roles` table) define hoy
    /// `admin` y `member` por contexto; el frontend no infiere comportamiento,
    /// solo presenta los keys disponibles y deja que el backend valide.
    private struct AssignableRole {
        let key: String
        let label: String
        let symbol: String
    }

    private static let roleCatalog: [AssignableRole] = [
        AssignableRole(key: "admin",  label: "Admin",   symbol: "person.badge.shield.checkmark"),
        AssignableRole(key: "member", label: "Miembro", symbol: "person.fill")
    ]

    private func assignableRoles(for member: ContextMember) -> [AssignableRole] {
        let current = Set(member.roles)
        return Self.roleCatalog.filter { !current.contains($0.key) }
    }

    private func obligationSymbol(_ kind: String) -> String {
        switch kind {
        case "action":      return "checklist"
        case "approval":    return "checkmark.seal.fill"
        case "delivery":    return "shippingbox.fill"
        case "attendance":  return "person.crop.circle.badge.checkmark.fill"
        case "document":    return "doc.text.fill"
        case "reservation": return "calendar.badge.clock"
        case "money":       return "dollarsign.circle.fill"
        default:            return "circle.dashed"
        }
    }
}

/// Wrapper Identifiable para `.sheet(item:)`.
private struct ObligationIdSheetWrapper: Identifiable {
    let id: UUID
}

#Preview("Detalle de miembro") {
    NavigationStack {
        MemberDetailView(
            member: ContextMember(
                actorId: MockRuulRPCClient.DemoIds.david,
                displayName: "David",
                membershipType: "member",
                joinedAt: Date(),
                roles: ["member"]
            ),
            context: AppContext(
                id: MockRuulRPCClient.DemoIds.cenaSemanal,
                kind: .collective,
                subtype: "friend_group",
                displayName: "Cena Semanal",
                roles: ["admin"]
            ),
            store: MembersStore(
                rpc: MockRuulRPCClient.demo(),
                previewMembers: [],
                permissions: MockRuulRPCClient.allPermissions
            ),
            myActorId: MockRuulRPCClient.DemoIds.jose
        )
    }
}
