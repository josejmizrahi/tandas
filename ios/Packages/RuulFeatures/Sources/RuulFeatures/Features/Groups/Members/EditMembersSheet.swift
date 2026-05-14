import SwiftUI
import OSLog
import RuulUI
import RuulCore

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
public struct EditMembersSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let group: RuulCore.Group

    public init(group: RuulCore.Group) {
        self.group = group
    }

    @State private var rows: [MemberWithProfile] = []
    @State private var isLoading: Bool = true
    @State private var loadError: String?

    /// The actor row corresponding to the signed-in user — needed by
    /// `GovernanceService.canPerform(...)` to gate destructive actions.
    @State private var actor: Member?

    @State private var pendingRemoval: MemberWithProfile?
    @State private var pendingProposal: MemberWithProfile?
    @State private var proposalSent: MemberWithProfile?
    @State private var isRemoving: Bool = false
    @State private var isProposing: Bool = false
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

    public var body: some View {
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
        .confirmationDialog(
            proposalDialogTitle,
            isPresented: proposalBinding,
            titleVisibility: .visible,
            presenting: pendingProposal
        ) { mwp in
            Button("Abrir votación") {
                Task { await proposeRemoval(mwp) }
            }
            Button("Cancelar", role: .cancel) {
                pendingProposal = nil
            }
        } message: { mwp in
            // Governance returned `.requiresVote` for `.removeMembers` —
            // explain the consequence so voters know what they're about
            // to be asked, then start the vote on confirm.
            Text("Tu nivel de gobernanza requiere votación. Si el grupo aprueba, \(mwp.displayName) sale automáticamente. Si rechaza, se queda.")
        }
        .alert(
            "Votación abierta",
            isPresented: proposalSentBinding,
            presenting: proposalSent
        ) { _ in
            Button("Listo") { proposalSent = nil }
        } message: { mwp in
            Text("Vamos a avisarle al grupo. Cuando cierre la votación, si pasa, \(mwp.displayName) sale del grupo.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && rows.isEmpty {
            RuulLoadingState()
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
                    swipeActionFor(mwp)
                }
                .contextMenu {
                    contextActionFor(mwp)
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
                Text("Quitar miembros requiere votación. Deslizá la fila o tocá largo para proponer remoción al grupo.")
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

    /// True when governance lets the actor remove the member directly
    /// (admin-style flow: DELETE on group_members with no vote in
    /// between).
    private func canRemove(_ mwp: MemberWithProfile) -> Bool {
        guard case .allowed = removeDecision else { return false }
        return canTargetForRemoval(mwp)
    }

    /// True when governance returned `.requiresVote`. The actor opens
    /// a `member_removal` vote; the group decides. Server trigger
    /// `remove_member_on_removal_pass` (migration 00035) applies the
    /// deletion when the vote resolves passed.
    private func canPropose(_ mwp: MemberWithProfile) -> Bool {
        guard case .requiresVote = removeDecision else { return false }
        return canTargetForRemoval(mwp)
    }

    /// Shared eligibility checks for both direct and vote-mediated
    /// removal. Founder can never be removed (would orphan the group).
    /// Self-removal goes through the regular "Salir del grupo" flow on
    /// the parent sheet, so this destination stays focused on
    /// other-people actions.
    private func canTargetForRemoval(_ mwp: MemberWithProfile) -> Bool {
        if mwp.member.userId == currentUserId { return false }
        if mwp.member.isFounder { return false }
        return true
    }

    @ViewBuilder
    private func swipeActionFor(_ mwp: MemberWithProfile) -> some View {
        if canRemove(mwp) {
            Button(role: .destructive) {
                pendingRemoval = mwp
            } label: {
                Label("Quitar", systemImage: "person.fill.xmark")
            }
        } else if canPropose(mwp) {
            // Tinted instead of destructive — opening a vote is not by
            // itself destructive (the group still has to approve).
            Button {
                pendingProposal = mwp
            } label: {
                Label("Proponer", systemImage: "hand.raised")
            }
            .tint(Color.ruulAccent)
        }
    }

    @ViewBuilder
    private func contextActionFor(_ mwp: MemberWithProfile) -> some View {
        if canRemove(mwp) {
            Button(role: .destructive) {
                pendingRemoval = mwp
            } label: {
                Label("Quitar del grupo", systemImage: "person.fill.xmark")
            }
        } else if canPropose(mwp) {
            Button {
                pendingProposal = mwp
            } label: {
                Label("Proponer remoción", systemImage: "hand.raised")
            }
        }
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

    private var proposalDialogTitle: String {
        guard let p = pendingProposal else { return "Proponer remoción" }
        return "¿Proponer remover a \(p.displayName)?"
    }

    private var proposalBinding: Binding<Bool> {
        Binding(
            get: { pendingProposal != nil },
            set: { if !$0 { pendingProposal = nil } }
        )
    }

    private var proposalSentBinding: Binding<Bool> {
        Binding(
            get: { proposalSent != nil },
            set: { if !$0 { proposalSent = nil } }
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
            try await app.groupsRepo.removeMember(
                groupId: mwp.member.groupId,
                userId: mwp.member.userId,
                reason: nil
            )
            await MainActor.run {
                rows.removeAll { $0.id == mwp.id }
            }
        } catch {
            log.warning("removeMember failed: \(error.localizedDescription)")
            let raw = error.localizedDescription.lowercased()
            // remove_member (mig 00120) routes through resolve_governance.
            // When the group's `member.remove` policy is vote_required the
            // RPC raises a recognizable exception — auto-promote to the
            // vote-driven path instead of bubbling the raw error to the
            // user. Same code we'd run if they'd tapped "propose removal".
            if raw.contains("governance requires vote") {
                Task { await proposeRemoval(mwp) }
                return
            }
            await MainActor.run {
                self.rowError = "No pudimos quitar a \(mwp.displayName): \(mapRemoveError(error))"
            }
        }
    }

    /// Maps the most common remove_member rejections to Spanish copy so
    /// the swipe error doesn't leak raw Postgres text. The
    /// `governance requires vote` case is handled separately upstream
    /// (auto-promote to proposeRemoval), so we don't need to map it
    /// here.
    private func mapRemoveError(_ error: Error) -> String {
        let msg = error.localizedDescription.lowercased()
        if msg.contains("governance denied") || msg.contains("policy denied") {
            return "Este grupo no permite quitar miembros."
        }
        if msg.contains("admin only") || msg.contains("forbidden") {
            return "Solo administradores pueden quitar miembros."
        }
        if msg.contains("cannot remove themselves") {
            return "Los administradores no pueden quitarse a sí mismos. Para irte, usa \"Salir del grupo\"."
        }
        if msg.contains("not an active member") {
            return "Esa persona ya no está en el grupo."
        }
        return error.localizedDescription
    }

    /// Opens a `member_removal` vote via `VoteRepository.startVote` so
    /// the group decides instead of the actor. The vote's `reference_id`
    /// is the target user's `auth.users.id`, matching the contract that
    /// `remove_member_on_removal_pass` (migration 00035) keys off when
    /// it deletes the `group_members` row on a passed resolution.
    /// Payload is empty — no per-vote context beyond the title is
    /// required for V1.
    private func proposeRemoval(_ mwp: MemberWithProfile) async {
        guard !isProposing else { return }
        isProposing = true
        rowError = nil
        defer {
            Task { @MainActor in
                isProposing = false
                pendingProposal = nil
            }
        }
        do {
            _ = try await app.voteRepo.startVote(
                groupId: group.id,
                voteType: .memberRemoval,
                referenceId: mwp.member.userId,
                title: "Quitar a \(mwp.displayName)",
                description: nil,
                payload: JSONConfig.empty
            )
            await MainActor.run {
                proposalSent = mwp
            }
        } catch {
            log.warning("startVote(memberRemoval) failed: \(error.localizedDescription)")
            await MainActor.run {
                self.rowError = "No pudimos abrir la votación: \(mapVoteError(error))"
            }
        }
    }

    /// Surfaces the most common server-side rejections in Spanish so
    /// the swipe error doesn't leak raw Postgres text. Falls back to
    /// the underlying message for unrecognized cases.
    private func mapVoteError(_ error: Error) -> String {
        let msg = error.localizedDescription.lowercased()
        if msg.contains("unique") || msg.contains("already") {
            return "Ya hay una votación abierta sobre este miembro."
        }
        if msg.contains("permission") || msg.contains("rls") || msg.contains("policy") {
            return "No tenés permiso para abrir esta votación."
        }
        return error.localizedDescription
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

    /// Resolves the active `member.remove` policy via the server resolver
    /// (migs 00088 + 00111) and translates the PolicyDecision into the
    /// GovernanceDecision shape the rest of this view keys off (canRemove
    /// / canPropose / swipe + context actions). Translation is intentional
    /// — keeps every other call site unchanged while swapping the source
    /// of truth from the legacy whoCanRemoveMembers jsonb to group_policies.
    ///
    /// Doctrine: removeMembers IS a Group Rule (governs the group as a
    /// system), so its config lives next to rule.toggle / rule.update_amount
    /// in `group_policies`, not in the legacy flat `governance` jsonb.
    private func refreshGovernanceDecision() async {
        guard let uid = currentUserId else {
            removeDecision = .denied(reason: .inactiveMember)
            return
        }
        do {
            let decision = try await app.policyRepo.resolve(
                groupId: group.id,
                actorUserId: uid,
                action: .memberRemove,
                targetPayload: [:]
            )
            await MainActor.run { self.removeDecision = Self.translate(decision) }
        } catch {
            log.debug("policyRepo.resolve(.memberRemove) threw: \(error.localizedDescription)")
            await MainActor.run {
                self.removeDecision = .denied(reason: .inactiveMember)
            }
        }
    }

    /// Bridges `PolicyDecision` (resolver outcome) into `GovernanceDecision`
    /// (the legacy enum the V1 UI here was built against). `.adminOnly`
    /// collapses into `.denied(.notFounder)` — the only consumer that
    /// distinguishes "admin-only blocked" from "vote denied" is the swipe
    /// helper, which only cares whether the actor can act at all.
    private static func translate(_ decision: PolicyDecision) -> GovernanceDecision {
        switch decision {
        case .allowed:
            return .allowed
        case .voteRequired(let q, let t, _):
            return .requiresVote(quorumPercent: q, thresholdPercent: t)
        case .adminOnly:
            return .denied(reason: .notFounder)
        case .denied:
            return .denied(reason: .inactiveMember)
        }
    }
}
