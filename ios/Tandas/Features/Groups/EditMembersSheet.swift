import SwiftUI
import OSLog
import RuulUI

/// Member-management surface presented from `GroupInfoSheet` (F0 #4).
///
/// V1 actions (this sheet):
///   1. Drag-reorder rows → `set_turn_order` RPC (00004 — admin-only,
///      ignores inactive members). The whole list reorders client-side
///      and persists on drop.
///   2. Swipe-to-delete (or context menu) "Quitar del grupo" → DELETE on
///      `group_members` via PostgREST. RLS policy `members_delete` (00002)
///      allows admins to remove anyone in their group; we additionally
///      gate via `GovernanceService.canPerform(.removeMembers, ...)` so
///      the destructive option is only offered when policy permits it.
///   3. Confirmation dialog before any DELETE.
///
/// V2 (deferred — documented in the audit follow-ups):
///   - "Promover a admin": no server-side RPC exists yet for the
///     `roles` jsonb update with governance check. Adding the RPC + UI
///     is its own task.
///   - `vote_type='member_removal'` integration when `canPerform`
///     returns `.requiresVote` — currently we just disable the action
///     and explain.
struct EditMembersSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let group: Group

    @State private var rows: [MemberWithProfile] = []
    @State private var isLoading: Bool = true
    @State private var loadError: String?

    /// The actor row corresponding to the signed-in user — needed by
    /// `GovernanceService.canPerform(...)` to gate destructive actions.
    @State private var actor: Member?

    @State private var pendingRemoval: MemberWithProfile?
    @State private var isRemoving: Bool = false
    @State private var rowError: String?

    @State private var isPersistingOrder: Bool = false
    @State private var orderError: String?

    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "groups.edit-members")

    private var currentUserId: UUID? { app.session?.user.id }

    /// Whether the current user is allowed to remove members at all
    /// (i.e. governance level for `.removeMembers` is currently `.allowed`
    /// for them). When `.requiresVote` we still render the swipe action,
    /// but tapping it surfaces the "abrí una votación" message instead of
    /// performing the DELETE — that flow is V2.
    @State private var removeDecision: GovernanceDecision = .denied(reason: .inactiveMember)

    /// Whether the user can reorder the turn queue. Server-side
    /// `set_turn_order` is admin-only, so we gate visually on
    /// `member.isFounder` (V1 admin == founder). When `false`, drag is
    /// disabled but the list still shows.
    private var canReorderTurn: Bool { actor?.isFounder == true }

    var body: some View {
        NavigationStack {
            content
                .background(Color.ruulBackground.ignoresSafeArea())
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cerrar") { dismiss() }
                            .foregroundStyle(Color.ruulTextSecondary)
                    }
                    ToolbarItem(placement: .principal) {
                        Text("Editar miembros")
                            .ruulTextStyle(RuulTypography.headline)
                            .foregroundStyle(Color.ruulTextPrimary)
                    }
                }
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarBackground(Color.ruulBackground, for: .navigationBar)
        }
        .task { await load() }
        .confirmationDialog(
            removalDialogTitle,
            isPresented: removalBinding,
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { mwp in
            Button("Quitar del grupo", role: .destructive) {
                Task { await remove(mwp) }
            }
            Button("Cancelar", role: .cancel) {
                pendingRemoval = nil
            }
        } message: { mwp in
            Text("\(mwp.displayName) va a perder acceso al grupo, sus eventos y multas. Vas a tener que invitarla de nuevo si querés que vuelva.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && rows.isEmpty {
            ProgressView()
                .tint(Color.ruulAccent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError, rows.isEmpty {
            VStack(spacing: RuulSpacing.sm) {
                Text("No pudimos cargar los miembros.")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text(loadError)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                Button("Reintentar") { Task { await load() } }
                    .foregroundStyle(Color.ruulAccent)
            }
            .padding(RuulSpacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            membersList
        }
    }

    // MARK: - Members list

    private var membersList: some View {
        List {
            Section {
                membersForEach
            } header: {
                listHeader
            } footer: {
                listFooter
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.ruulBackground)
        .environment(\.editMode, .constant(canReorderTurn ? EditMode.active : EditMode.inactive))
    }

    @ViewBuilder
    private var membersForEach: some View {
        ForEach(rows) { mwp in
            memberRow(mwp)
                .listRowBackground(Color.ruulSurface)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if canRemove(mwp) {
                        Button(role: .destructive) {
                            pendingRemoval = mwp
                        } label: {
                            Label("Quitar", systemImage: "person.fill.xmark")
                        }
                    }
                }
                .contextMenu {
                    if canRemove(mwp) {
                        Button(role: .destructive) {
                            pendingRemoval = mwp
                        } label: {
                            Label("Quitar del grupo", systemImage: "person.fill.xmark")
                        }
                    }
                }
        }
        .onMove { source, destination in
            // Accepts the gesture only when reorder is allowed; otherwise
            // we silently drop it. Edit mode is force-`.inactive` for
            // non-founders so the drag handles aren't shown anyway.
            guard canReorderTurn else { return }
            handleMove(source, to: destination)
        }
    }

    @ViewBuilder
    private var listHeader: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
            Text("MIEMBROS \(rows.isEmpty ? "" : "(\(rows.count))")")
                .ruulTextStyle(RuulTypography.footnote)
                .foregroundStyle(Color.ruulTextSecondary)
            if canReorderTurn {
                Text("Arrastrá para cambiar el turno de anfitrión.")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
        }
        .textCase(nil)
        .padding(.bottom, RuulSpacing.xxs)
    }

    @ViewBuilder
    private var listFooter: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
            if let rowError {
                Text(rowError)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulNegative)
            }
            if let orderError {
                Text(orderError)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulNegative)
            }
            if case .requiresVote = removeDecision {
                Text("Quitar miembros requiere una votación. Vas a poder abrirla cuando esté lista la pantalla de votos genéricos.")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            if isPersistingOrder {
                HStack(spacing: RuulSpacing.xs) {
                    ProgressView().scaleEffect(0.8).tint(Color.ruulAccent)
                    Text("Guardando turno…")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
            }
        }
        .textCase(nil)
        .padding(.top, RuulSpacing.xxs)
    }

    private func memberRow(_ mwp: MemberWithProfile) -> some View {
        let isYou = mwp.member.userId == currentUserId
        return HStack(spacing: RuulSpacing.sm) {
            RuulAvatar(name: mwp.displayName, imageURL: mwp.avatarURL, size: .medium)
            VStack(alignment: .leading, spacing: 2) {
                Text(isYou ? "\(mwp.displayName) (tú)" : mwp.displayName)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(1)
                if mwp.member.isFounder {
                    Text("FOUNDER")
                        .ruulTextStyle(RuulTypography.footnote)
                        .foregroundStyle(Color.ruulAccent)
                } else if mwp.member.role == "admin" {
                    Text("ADMIN")
                        .ruulTextStyle(RuulTypography.footnote)
                        .foregroundStyle(Color.ruulAccent)
                }
            }
            Spacer()
        }
        .padding(.vertical, RuulSpacing.xxs)
        .accessibilityLabel(Text(mwp.displayName))
    }

    // MARK: - Reordering

    private func handleMove(_ source: IndexSet, to destination: Int) {
        var snapshot = rows
        snapshot.move(fromOffsets: source, toOffset: destination)
        let userIds = snapshot.map { $0.member.userId }
        rows = snapshot
        Task { await persistOrder(userIds) }
    }

    private func persistOrder(_ userIds: [UUID]) async {
        guard !isPersistingOrder else { return }
        isPersistingOrder = true
        orderError = nil
        defer { Task { @MainActor in isPersistingOrder = false } }
        do {
            try await app.groupsRepo.setTurnOrder(groupId: group.id, userIds: userIds)
        } catch {
            log.warning("setTurnOrder failed: \(error.localizedDescription)")
            await MainActor.run {
                self.orderError = "No pudimos guardar el turno: \(error.localizedDescription)"
            }
            // Refresh from server so the local order doesn't drift from truth.
            await load(silent: true)
        }
    }

    // MARK: - Removal

    private func canRemove(_ mwp: MemberWithProfile) -> Bool {
        guard case .allowed = removeDecision else { return false }
        // Self-removal goes through the regular "Salir del grupo" flow on
        // the parent sheet — keep this destination focused on admin actions.
        if mwp.member.userId == currentUserId { return false }
        // Founder can never be removed (would orphan the group).
        if mwp.member.isFounder { return false }
        return true
    }

    private var removalDialogTitle: String {
        guard let p = pendingRemoval else { return "Quitar miembro" }
        return "¿Quitar a \(p.displayName)?"
    }

    private var removalBinding: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        )
    }

    private func remove(_ mwp: MemberWithProfile) async {
        guard !isRemoving else { return }
        isRemoving = true
        rowError = nil
        defer {
            Task { @MainActor in
                isRemoving = false
                pendingRemoval = nil
            }
        }
        do {
            try await app.groupsRepo.removeMember(memberId: mwp.member.id)
            await MainActor.run {
                rows.removeAll { $0.id == mwp.id }
            }
        } catch {
            log.warning("removeMember failed: \(error.localizedDescription)")
            await MainActor.run {
                self.rowError = "No pudimos quitar a \(mwp.displayName): \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Loading

    private func load(silent: Bool = false) async {
        if !silent { isLoading = true }
        defer { Task { @MainActor in isLoading = false } }
        do {
            let fetched = try await app.groupsRepo.membersWithProfiles(of: group.id)
            // Preserve server-side turn order: rows arrive in DB order from
            // `select * from group_members` which respects insertion. We
            // sort founders first, then by `displayName` only when the row
            // has no `joined_at`-based order signal — but to keep the
            // turn-order semantics intact for drag, we trust the natural
            // server order here (set_turn_order rewrites turn_order; an
            // ORDER BY on the server side belongs to a future polish).
            await MainActor.run {
                self.rows = fetched
                self.actor = fetched.first(where: { $0.member.userId == currentUserId })?.member
                self.loadError = nil
            }
            await refreshGovernanceDecision()
        } catch {
            log.warning("load members failed: \(error.localizedDescription)")
            await MainActor.run {
                self.loadError = error.localizedDescription
            }
        }
    }

    private func refreshGovernanceDecision() async {
        guard let me = actor else {
            removeDecision = .denied(reason: .inactiveMember)
            return
        }
        do {
            let decision = try await app.governance.canPerform(
                .removeMembers,
                member: me,
                in: group,
                context: nil
            )
            await MainActor.run { self.removeDecision = decision }
        } catch {
            log.debug("governance.canPerform threw: \(error.localizedDescription)")
            await MainActor.run {
                self.removeDecision = .denied(reason: .inactiveMember)
            }
        }
    }
}
