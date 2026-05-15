import SwiftUI
import UIKit
import OSLog
import RuulUI
import RuulCore

/// RuulCore.Group info sheet shown from HomeView header (person.badge.plus icon).
/// Three sections in priority order:
///
/// 1. Invite — code card (tap to copy) + universal link + system Share
/// 2. Members — list of members + profiles for the active group
/// 3. Leave — destructive button at the bottom
///
/// Replaces the original InviteShareSheet (invite-only). Editing the group
/// name / kicking members are deferred to a later sprint (admin tools).
public struct GroupInfoSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let group: RuulCore.Group

    public init(group: RuulCore.Group) {
        self.group = group
    }

    @State private var members: [MemberWithProfile] = []
    @State private var isLoadingMembers: Bool = true
    @State private var copied: Bool = false
    @State private var leaveConfirmPresented: Bool = false
    @State private var isLeaving: Bool = false
    @State private var leaveError: String?
    @State private var settingsPresented: Bool = false
    @State private var governancePresented: Bool = false
    @State private var groupRulesPresented: Bool = false
    @State private var editMembersPresented: Bool = false
    /// Cached "can the current user remove members in this group?" — used to
    /// gate the entry point to `EditMembersSheet`. We resolve it once after
    /// the members list loads (so we have the actor's `Member` row).
    @State private var canManageMembers: Bool = false
    /// Locally tracked override for the group used to render this sheet —
    /// we keep it in sync after governance edits so the summary refreshes
    /// without a parent re-render.
    @State private var liveGroup: RuulCore.Group?
    @State private var templateDisplayName: String?

    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "groups.info")

    private var shareMessage: String {
        InviteLinkGenerator.shareMessage(groupName: group.name, code: group.inviteCode)
    }

    private var currentUserId: UUID? {
        app.session?.user.id
    }

    private var isCurrentUserAdmin: Bool {
        guard let uid = currentUserId else { return false }
        return members.first(where: { $0.member.userId == uid })?.member.role == "admin"
    }

    private var currentGroup: RuulCore.Group { liveGroup ?? group }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.xl) {
                    profileHeader
                    governanceSection
                    if isCurrentUserAdmin {
                        editButton
                    }
                    if canManageMembers {
                        editMembersButton
                    }
                    inviteSection
                    membersSection
                    leaveSection
                }
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.top, RuulSpacing.md)
                .padding(.bottom, RuulSpacing.xxl)
            }
            .ruulAmbientScreen(palette: app.activeGroup?.ambientPalette)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar") { dismiss() }
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                ToolbarItem(placement: .principal) {
                    Text(currentGroup.name)
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                        .lineLimit(1)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.ruulBackground, for: .navigationBar)
        }
        .task {
            await loadMembers()
            await loadTemplateDisplayName()
        }
        .sheet(isPresented: $settingsPresented) {
            GroupSettingsSheet(group: currentGroup)
                .environment(app)
                .ruulSheetChrome(detents: [.large])
        }
        .sheet(isPresented: $governancePresented) {
            GovernanceSettingsView(group: currentGroup) { updated in
                liveGroup = updated
            }
            .environment(app)
            .ruulSheetChrome(detents: [.large])
        }
        .sheet(isPresented: $groupRulesPresented) {
            GroupRulesSettingsView(coordinator: GroupRulesCoordinator(
                group: currentGroup,
                actorUserId: app.session?.user.id ?? UUID(),
                policyRepo: app.policyRepo
            ))
            .environment(app)
            .ruulSheetChrome(detents: [.large])
        }
        .sheet(isPresented: $editMembersPresented, onDismiss: {
            // Refresh the read-only list under the entry button so removed
            // rows or reorders show up immediately.
            Task { await loadMembers() }
        }) {
            EditMembersSheet(group: currentGroup)
                .environment(app)
                .ruulSheetChrome(detents: [.large])
        }
        .confirmationDialog(
            "¿Salir de \(currentGroup.name)?",
            isPresented: $leaveConfirmPresented,
            titleVisibility: .visible
        ) {
            Button("Salir del grupo", role: .destructive) {
                Task { await leaveGroup() }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Vas a perder acceso a los eventos y multas de este grupo. Para volver, alguien va a tener que invitarte de nuevo.")
        }
    }

    // MARK: - Profile header

    private var profileHeader: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            // Cover or solid placeholder. Cover edit is P1 #10 — for V1
            // we render whatever was set at onboarding (if any) and show
            // a subtle accent gradient when nothing is configured.
            ZStack(alignment: .bottomLeading) {
                if let coverName = currentGroup.coverImageName, !coverName.isEmpty {
                    Image(coverName)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 120)
                        .clipped()
                } else {
                    LinearGradient(
                        colors: [Color.ruulAccent.opacity(0.65), Color.ruulAccent.opacity(0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(height: 120)
                }
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(currentGroup.name)
                    .ruulTextStyle(RuulTypography.title)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(2)
                Text(headerSubtitle)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
        }
    }

    private var headerSubtitle: String {
        let typeLabel = templateDisplayName ?? currentGroup.category.displayName
        let countLabel = members.isEmpty
            ? "Cargando miembros…"
            : "\(members.count) \(members.count == 1 ? "miembro" : "miembros")"
        return "\(typeLabel) · \(countLabel)"
    }

    private func loadTemplateDisplayName() async {
        let templateId = currentGroup.effectiveBaseTemplate
        guard let template = await app.templateRegistry.template(id: templateId) else {
            templateDisplayName = nil
            return
        }
        templateDisplayName = template.effectiveDisplayName
    }

    // MARK: - Governance summary

    private var governanceSection: some View {
        let g = currentGroup.effectiveGovernance
        let canEdit = isCurrentUserAdmin && g.whoCanModifyGovernance == .founder
        return VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                sectionLabel("GOBIERNO")
                Spacer()
                Button("Reglas") { groupRulesPresented = true }
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulAccent)
                if canEdit {
                    Button("Editar") { governancePresented = true }
                        .ruulTextStyle(RuulTypography.callout)
                        .foregroundStyle(Color.ruulAccent)
                        .padding(.leading, RuulSpacing.sm)
                }
            }
            VStack(spacing: RuulSpacing.xs) {
                governanceRow(label: "Modifica reglas",  value: permissionLabel(g.whoCanModifyRules))
                governanceRow(label: "Inicia votaciones", value: permissionLabel(g.whoCanCreateVotes))
                governanceRow(label: "Quita miembros",   value: permissionLabel(g.whoCanRemoveMembers))
                governanceRow(
                    label: "Votación",
                    value: "\(g.votingQuorumPercent)% quórum · \(g.votingThresholdPercent)% mayoría · \(g.votingDurationHours)h"
                )
                governanceRow(
                    label: "Anonimato",
                    value: g.votesAreAnonymous ? "Votos anónimos" : "Votos públicos"
                )
            }
            .padding(RuulSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 1)
            )

            if !canEdit && g.whoCanModifyGovernance != .founder {
                Text("Para cambiar el gobierno, abrí una votación.")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextTertiary)
                    .padding(.leading, RuulSpacing.xxs)
            }
        }
    }

    private func governanceRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .ruulTextStyle(RuulTypography.callout)
                .foregroundStyle(Color.ruulTextSecondary)
            Spacer()
            Text(value)
                .ruulTextStyle(RuulTypography.callout)
                .foregroundStyle(Color.ruulTextPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func permissionLabel(_ level: PermissionLevel) -> String {
        switch level {
        case .founder:           return "Solo founder"
        case .anyMember:         return "Cualquiera"
        case .majorityVote:      return "Votación"
        case .supermajorityVote: return "Votación 2/3"
        case .host:              return "Solo host"
        case .treasurer:         return "Tesorero"
        case .unknown(let s):    return s
        }
    }

    // MARK: - Edit (admin only)

    private var editButton: some View {
        Button {
            settingsPresented = true
        } label: {
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: "slider.horizontal.3")
                    .ruulTextStyle(RuulTypography.headlineMedium)
                    .foregroundStyle(Color.ruulAccent)
                    .frame(width: 36, height: 36)
                    .background(Color.ruulAccentMuted, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Editar grupo")
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Text("Vocabulario, multas, anfitrión")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .ruulTextStyle(RuulTypography.labelSemibold)
                    .foregroundStyle(Color.ruulTextTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, RuulSpacing.md)
            .padding(.vertical, RuulSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Editar configuración del grupo")
    }

    // MARK: - Edit members entry (F0 #4)

    private var editMembersButton: some View {
        Button {
            editMembersPresented = true
        } label: {
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: "person.2.badge.gearshape")
                    .ruulTextStyle(RuulTypography.headlineMedium)
                    .foregroundStyle(Color.ruulAccent)
                    .frame(width: 36, height: 36)
                    .background(Color.ruulAccentMuted, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Editar miembros")
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Text("Quitar y reordenar turno")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .ruulTextStyle(RuulTypography.labelSemibold)
                    .foregroundStyle(Color.ruulTextTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, RuulSpacing.md)
            .padding(.vertical, RuulSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Editar miembros del grupo")
    }

    // MARK: - Invite

    private var inviteSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            sectionLabel("INVITAR")
            codeCard
            // Beta 1 W1-5: previous `linkRow` rendered the universal
            // https://ruul.app/invite/<code> URL — broken until AASA
            // ships. Removed; codeCard already exposes the canonical
            // affordance and shareButton sends the plaintext message.
            shareButton
        }
    }

    private var codeCard: some View {
        Button {
            UIPasteboard.general.string = group.inviteCode
            copyFeedback()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CÓDIGO")
                        .ruulTextStyle(RuulTypography.footnote)
                        .foregroundStyle(Color.ruulTextTertiary)
                    Text(group.inviteCode.uppercased())
                        .ruulTextStyle(RuulTypography.monoLarge)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
                Spacer()
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .ruulTextStyle(RuulTypography.headlineMedium)
                    .foregroundStyle(copied ? Color.ruulPositive : Color.ruulTextSecondary)
                    .accessibilityHidden(true)
            }
            .padding(RuulSpacing.md)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                    .stroke(Color.ruulSeparator, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copiar código")
        .sensoryFeedback(.success, trigger: copied)
    }

    private var shareButton: some View {
        // Beta 1 W1-5: share the plaintext message as the primary item.
        // Previous `item: url` sent the dead https://ruul.app URL; tapping
        // it in WhatsApp opened Safari to a 404 (no AASA wired). The
        // message itself (with the uppercased code) is the affordance now.
        ShareLink(
            item: shareMessage,
            subject: Text("Te invito a \(group.name)")
        ) {
            HStack {
                Image(systemName: "square.and.arrow.up")
                    .font(RuulTypography.headline.font)
                    .accessibilityHidden(true)
                Text("Compartir")
                    .ruulTextStyle(RuulTypography.body)
            }
            .foregroundStyle(Color.ruulTextInverse)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .background(Capsule().fill(Color.ruulAccent))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Members

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            sectionLabel("MIEMBROS \(memberCountSuffix)")
            if isLoadingMembers && members.isEmpty {
                HStack {
                    Spacer()
                    ProgressView().tint(Color.ruulAccent)
                    Spacer()
                }
                .padding(.vertical, RuulSpacing.md)
            } else if members.isEmpty {
                Text("No pudimos cargar los miembros.")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            } else {
                VStack(spacing: RuulSpacing.xs) {
                    ForEach(members) { mwp in
                        NavigationLink {
                            MemberDetailView(
                                memberWithProfile: mwp,
                                group: currentGroup,
                                isCurrentUser: mwp.member.userId == currentUserId
                            )
                        } label: {
                            memberRow(mwp)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var memberCountSuffix: String {
        members.isEmpty ? "" : "(\(members.count))"
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
                if mwp.member.role == "admin" {
                    Text("ADMIN")
                        .ruulTextStyle(RuulTypography.footnote)
                        .foregroundStyle(Color.ruulAccent)
                }
            }
            Spacer()
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .stroke(Color.ruulSeparator, lineWidth: 1)
        )
    }

    // MARK: - Leave

    private var leaveSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            if let leaveError {
                Text(leaveError)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulNegative)
            }
            Button {
                leaveConfirmPresented = true
            } label: {
                HStack {
                    if isLeaving {
                        ProgressView().tint(Color.ruulNegative)
                    } else {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .ruulTextStyle(RuulTypography.subheadMedium)
                            .accessibilityHidden(true)
                        Text("Salir del grupo")
                            .ruulTextStyle(RuulTypography.body)
                    }
                    Spacer()
                }
                .foregroundStyle(Color.ruulNegative)
                .padding(.horizontal, RuulSpacing.md)
                .padding(.vertical, RuulSpacing.md)
                .background(
                    RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                        .stroke(Color.ruulSeparator, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(isLeaving)
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .ruulTextStyle(RuulTypography.footnote)
            .foregroundStyle(Color.ruulTextSecondary)
            .padding(.leading, RuulSpacing.xxs)
    }

    private func copyFeedback() {
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run { copied = false }
        }
    }

    private func loadMembers() async {
        isLoadingMembers = true
        defer { isLoadingMembers = false }
        do {
            let rows = try await app.groupsRepo.membersWithProfiles(of: group.id)
            members = rows.sorted { lhs, rhs in
                if lhs.member.role != rhs.member.role {
                    return lhs.member.role == "admin"
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            await refreshCanManageMembers()
        } catch {
            log.warning("members load failed: \(error.localizedDescription)")
        }
    }

    /// Determines whether the entry-point button to `EditMembersSheet`
    /// should be visible. We surface it whenever the current user can
    /// remove members per governance rules — the sheet itself re-checks
    /// before performing destructive actions.
    private func refreshCanManageMembers() async {
        guard let uid = currentUserId,
              let me = members.first(where: { $0.member.userId == uid })?.member else {
            await MainActor.run { canManageMembers = false }
            return
        }
        do {
            let decision = try await app.governance.canPerform(
                .removeMembers,
                member: me,
                in: currentGroup,
                context: nil
            )
            // Show the entry whenever the action is `.allowed`. For
            // `.requiresVote` we hide the button in V1 — opening a
            // member_removal vote is V2 and there's nothing else useful
            // the sheet can do yet (reorder is also founder-only).
            if case .allowed = decision {
                await MainActor.run { canManageMembers = true }
            } else {
                await MainActor.run { canManageMembers = false }
            }
        } catch {
            log.debug("governance.canPerform threw: \(error.localizedDescription)")
            await MainActor.run { canManageMembers = false }
        }
    }

    private func leaveGroup() async {
        guard !isLeaving else { return }
        isLeaving = true
        leaveError = nil
        defer { Task { @MainActor in isLeaving = false } }
        do {
            // `leaveGroup(groupId:)` routes through the leave_group RPC
            // (mig 00115) which soft-deletes + emits memberLeft. The
            // older `leave(_:)` direct-UPDATE path stays in the repo
            // for back-compat but skips the activity timeline.
            try await app.groupsRepo.leaveGroup(groupId: group.id)
            await app.refreshProfileAndGroups()
            await MainActor.run {
                if app.activeGroupId == group.id {
                    app.activeGroupId = app.groups.first?.id
                }
                dismiss()
            }
        } catch {
            log.warning("leave group failed: \(error.localizedDescription)")
            await MainActor.run {
                self.leaveError = "No pudimos salir del grupo: \(error.localizedDescription)"
            }
        }
    }
}
