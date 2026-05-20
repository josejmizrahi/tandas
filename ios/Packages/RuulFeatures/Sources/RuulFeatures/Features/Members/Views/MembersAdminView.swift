import SwiftUI
import RuulUI
import RuulCore

@MainActor
public struct MembersAdminView: View {
    @State var coordinator: MembersCoordinator
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var memberToKick: MemberWithProfile?
    @State private var proposeRemovalFor: MemberWithProfile?
    @State private var saving = false
    @State private var error: String?

    public var onInviteTap: (() -> Void)?

    public init(coordinator: MembersCoordinator, onInviteTap: (() -> Void)? = nil) {
        self._coordinator = State(initialValue: coordinator)
        self.onInviteTap = onInviteTap
    }

    public var body: some View {
        ZStack {
            Color.ruulBackground.ignoresSafeArea()
            content
        }
        .ruulSheetToolbar("Gestionar miembros")
        .toolbar {
            if let onInviteTap {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onInviteTap) {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Invitar miembros")
                }
            }
        }
        .alert("Echar a este miembro", isPresented: kickAlertBinding, presenting: memberToKick) { row in
            Button("Echar", role: .destructive) { Task { await kick(row) } }
            Button("Cancelar", role: .cancel) { memberToKick = nil }
        } message: { row in
            Text("\(row.displayName) perderá acceso al grupo.")
        }
        .fullScreenCover(item: $proposeRemovalFor) { target in
            if let creatorMemberId = coordinator.member(for: coordinator.actorUserId)?.member.id {
                CreateMemberRemovalSheet(
                    coordinator: CreateMemberRemovalCoordinator(
                        group: coordinator.group,
                        creatorMemberId: creatorMemberId,
                        prefilledTarget: target,
                        voteRepo: app.voteRepo,
                        groupsRepo: app.groupsRepo
                    )
                )
            }
        }
        .task { await coordinator.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        AsyncContentView(
            phase: coordinator.activePhase,
            onRetry: { await coordinator.refresh() },
            empty: {
                ContentUnavailableView {
                    Label("Sin miembros activos", systemImage: "person.2")
                } description: {
                    Text("Invita miembros con el botón “+” para empezar.")
                }
                .padding(RuulSpacing.lg)
            },
            loaded: { rows in
                List {
                    ForEach(rows) { row in
                        NavigationLink {
                            MemberDetailView(
                                memberWithProfile: row,
                                group: coordinator.group,
                                isCurrentUser: row.member.userId == coordinator.actorUserId,
                                canManageRoles: coordinator.canManageRoles,
                                founderCount: coordinator.founderCount,
                                adminCount: coordinator.adminCount,
                                onMemberChanged: { await coordinator.refresh() }
                            )
                        } label: {
                            adminRow(row)
                        }
                        .swipeActions(edge: .trailing) {
                            if row.member.userId != coordinator.actorUserId {
                                if coordinator.canRemoveMembers {
                                    Button(role: .destructive) {
                                        memberToKick = row
                                    } label: {
                                        Label("Echar", systemImage: "trash")
                                    }
                                }
                                Button {
                                    proposeRemovalFor = row
                                } label: {
                                    Label("Proponer voto", systemImage: "checkmark.bubble")
                                }
                                .tint(Color.orange)
                            }
                        }
                    }
                    .onMove(perform: moveMembers)
                }
                .listStyle(.plain)
                .environment(\.editMode, .constant(.active))
                .refreshable { await coordinator.refresh() }
            }
        )
    }

    @ViewBuilder
    private func adminRow(_ row: MemberWithProfile) -> some View {
        HStack(spacing: RuulSpacing.md) {
            RuulAvatar(name: row.displayName, imageURL: row.avatarURL, size: .medium)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName)
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
                Text(provenanceLabel(row.member))
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            Spacer()
            if row.member.isFounder {
                Text("FUNDADOR")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.ruulAccent)
            }
        }
        .padding(.vertical, RuulSpacing.xxs)
    }

    private func provenanceLabel(_ m: Member) -> String {
        switch m.joinedVia {
        case "founder_seed":  return "Fundador del grupo"
        case "invite_code":   return "Se unió por código"
        case "admin_add":     return "Agregado por un fundador"
        default:              return "Miembro"
        }
    }

    private var kickAlertBinding: Binding<Bool> {
        Binding(get: { memberToKick != nil }, set: { if !$0 { memberToKick = nil } })
    }

    private func kick(_ row: MemberWithProfile) async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            try await app.groupsRepo.removeMember(
                groupId: coordinator.group.id,
                userId: row.member.userId,
                reason: nil
            )
            await coordinator.refresh()
            memberToKick = nil
        } catch {
            self.error = "No pudimos remover al miembro."
        }
    }

    private func moveMembers(from source: IndexSet, to destination: Int) {
        var ordered = coordinator.activeMembers
        ordered.move(fromOffsets: source, toOffset: destination)
        Task {
            do {
                try await app.groupsRepo.setTurnOrder(
                    groupId: coordinator.group.id,
                    userIds: ordered.map { $0.member.userId }
                )
                await coordinator.refresh()
            } catch {
                self.error = "No pudimos guardar el nuevo orden."
                await coordinator.refresh() // snap back
            }
        }
    }
}
