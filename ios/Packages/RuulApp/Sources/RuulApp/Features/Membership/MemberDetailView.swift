import SwiftUI
import RuulCore

/// F.5 — detalle de un miembro: roles, antigüedad y acciones de admin
/// (asignar rol admin, remover del contexto).
public struct MemberDetailView: View {
    let member: ContextMember
    let context: AppContext
    let store: MembersStore
    let myActorId: UUID?

    @Environment(\.dismiss) private var dismiss
    @State private var runner = ActionRunner()
    @State private var isConfirmingRemove = false
    @State private var isConfirmingLeave = false

    public init(member: ContextMember, context: AppContext, store: MembersStore, myActorId: UUID?) {
        self.member = member
        self.context = context
        self.store = store
        self.myActorId = myActorId
    }

    private var isMe: Bool { member.actorId == myActorId }

    public var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    ActorInitialsView(name: member.displayName, size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(member.displayName)
                            .font(.headline)
                        if let type = member.membershipType {
                            Text(type == "founder" ? "Fundador" : "Miembro")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Información") {
                if let joined = member.joinedAt {
                    InfoRow(symbolName: "calendar", title: "Se unió", value: joined.formatted(date: .abbreviated, time: .omitted))
                }
                InfoRow(
                    symbolName: "person.text.rectangle",
                    title: "Roles",
                    value: member.roles.isEmpty ? "Miembro" : member.roles.joined(separator: ", ")
                )
            }

            // Acciones de admin
            if store.canManageMembers(in: context) && !isMe {
                Section("Administración") {
                    if !member.isAdmin {
                        Button {
                            Task {
                                await runner.run {
                                    try await store.assignRole(context: context, memberActorId: member.actorId, roleKey: "admin")
                                }
                            }
                        } label: {
                            Label("Hacer admin", systemImage: "person.badge.shield.checkmark")
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
        .navigationTitle(member.displayName)
        .navigationBarTitleDisplayMode(.inline)
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
    }
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
