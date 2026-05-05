import SwiftUI
import UIKit
import OSLog

/// Group info sheet shown from HomeView header (person.badge.plus icon).
/// Three sections in priority order:
///
/// 1. Invite — code card (tap to copy) + universal link + system Share
/// 2. Members — list of members + profiles for the active group
/// 3. Leave — destructive button at the bottom
///
/// Replaces the original InviteShareSheet (invite-only). Editing the group
/// name / kicking members are deferred to a later sprint (admin tools).
struct GroupInfoSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let group: Group

    @State private var members: [MemberWithProfile] = []
    @State private var isLoadingMembers: Bool = true
    @State private var copied: Bool = false
    @State private var leaveConfirmPresented: Bool = false
    @State private var isLeaving: Bool = false
    @State private var leaveError: String?
    @State private var settingsPresented: Bool = false
    @State private var governancePresented: Bool = false
    /// Locally tracked override for the group used to render this sheet —
    /// we keep it in sync after governance edits so the summary refreshes
    /// without a parent re-render.
    @State private var liveGroup: Group?

    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "groups.info")

    private var url: URL {
        InviteLinkGenerator.universal(code: group.inviteCode)
    }

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

    private var currentGroup: Group { liveGroup ?? group }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.s6) {
                    profileHeader
                    governanceSection
                    if isCurrentUserAdmin {
                        editButton
                    }
                    inviteSection
                    membersSection
                    leaveSection
                }
                .padding(.horizontal, RuulSpacing.s5)
                .padding(.top, RuulSpacing.s4)
                .padding(.bottom, RuulSpacing.s7)
            }
            .background(Color.ruulBackgroundCanvas.ignoresSafeArea())
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
            .toolbarBackground(Color.ruulBackgroundCanvas, for: .navigationBar)
        }
        .task { await loadMembers() }
        .sheet(isPresented: $settingsPresented) {
            GroupSettingsSheet(group: currentGroup)
                .environment(app)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $governancePresented) {
            GovernanceSettingsView(group: currentGroup) { updated in
                liveGroup = updated
            }
            .environment(app)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
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
        VStack(alignment: .leading, spacing: RuulSpacing.s3) {
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
                        colors: [Color.ruulAccentPrimary.opacity(0.65), Color.ruulAccentPrimary.opacity(0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(height: 120)
                }
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                    .stroke(Color.ruulBorderSubtle, lineWidth: 1)
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
        let typeLabel = currentGroup.groupType.displayName
        let countLabel = members.isEmpty
            ? "Cargando miembros…"
            : "\(members.count) \(members.count == 1 ? "miembro" : "miembros")"
        return "\(typeLabel) · \(countLabel)"
    }

    // MARK: - Governance summary

    private var governanceSection: some View {
        let g = currentGroup.effectiveGovernance
        let canEdit = isCurrentUserAdmin && g.whoCanModifyGovernance == .founder
        return VStack(alignment: .leading, spacing: RuulSpacing.s3) {
            HStack(alignment: .firstTextBaseline) {
                sectionLabel("GOBIERNO")
                Spacer()
                if canEdit {
                    Button("Editar") { governancePresented = true }
                        .ruulTextStyle(RuulTypography.callout)
                        .foregroundStyle(Color.ruulAccentPrimary)
                }
            }
            VStack(spacing: RuulSpacing.s2) {
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
            .padding(RuulSpacing.s4)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .fill(Color.ruulBackgroundElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .stroke(Color.ruulBorderSubtle, lineWidth: 1)
            )

            if !canEdit && g.whoCanModifyGovernance != .founder {
                Text("Para cambiar el gobierno, abrí una votación.")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextTertiary)
                    .padding(.leading, RuulSpacing.s1)
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
        }
    }

    // MARK: - Edit (admin only)

    private var editButton: some View {
        Button {
            settingsPresented = true
        } label: {
            HStack(spacing: RuulSpacing.s3) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.ruulAccentPrimary)
                    .frame(width: 36, height: 36)
                    .background(Color.ruulAccentSubtle, in: RoundedRectangle(cornerRadius: RuulRadius.md))
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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            .padding(.horizontal, RuulSpacing.s4)
            .padding(.vertical, RuulSpacing.s3)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .fill(Color.ruulBackgroundElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .stroke(Color.ruulBorderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Editar configuración del grupo")
    }

    // MARK: - Invite

    private var inviteSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s3) {
            sectionLabel("INVITAR")
            codeCard
            linkRow
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
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(copied ? Color.ruulSemanticSuccess : Color.ruulTextSecondary)
            }
            .padding(RuulSpacing.s4)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .fill(Color.ruulBackgroundElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .stroke(Color.ruulBorderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copiar código")
        .sensoryFeedback(.success, trigger: copied)
    }

    private var linkRow: some View {
        Text(url.absoluteString)
            .ruulTextStyle(RuulTypography.callout)
            .foregroundStyle(Color.ruulTextSecondary)
            .lineLimit(2)
            .padding(RuulSpacing.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .fill(Color.ruulBackgroundRecessed)
            )
    }

    private var shareButton: some View {
        ShareLink(
            item: url,
            subject: Text("Te invito a \(group.name)"),
            message: Text(shareMessage)
        ) {
            HStack {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 17, weight: .semibold))
                Text("Compartir")
                    .ruulTextStyle(RuulTypography.body)
            }
            .foregroundStyle(Color.ruulTextInverse)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .background(Capsule().fill(Color.ruulAccentPrimary))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Members

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s3) {
            sectionLabel("MIEMBROS \(memberCountSuffix)")
            if isLoadingMembers && members.isEmpty {
                HStack {
                    Spacer()
                    ProgressView().tint(Color.ruulAccentPrimary)
                    Spacer()
                }
                .padding(.vertical, RuulSpacing.s4)
            } else if members.isEmpty {
                Text("No pudimos cargar los miembros.")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            } else {
                VStack(spacing: RuulSpacing.s2) {
                    ForEach(members) { mwp in
                        memberRow(mwp)
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
        return HStack(spacing: RuulSpacing.s3) {
            RuulAvatar(name: mwp.displayName, imageURL: mwp.avatarURL, size: .medium)
            VStack(alignment: .leading, spacing: 2) {
                Text(isYou ? "\(mwp.displayName) (tú)" : mwp.displayName)
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .lineLimit(1)
                if mwp.member.role == "admin" {
                    Text("ADMIN")
                        .ruulTextStyle(RuulTypography.footnote)
                        .foregroundStyle(Color.ruulAccentPrimary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, RuulSpacing.s4)
        .padding(.vertical, RuulSpacing.s3)
        .background(
            RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                .fill(Color.ruulBackgroundElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                .stroke(Color.ruulBorderSubtle, lineWidth: 1)
        )
    }

    // MARK: - Leave

    private var leaveSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            if let leaveError {
                Text(leaveError)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulSemanticError)
            }
            Button {
                leaveConfirmPresented = true
            } label: {
                HStack {
                    if isLeaving {
                        ProgressView().tint(Color.ruulSemanticError)
                    } else {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 16, weight: .medium))
                        Text("Salir del grupo")
                            .ruulTextStyle(RuulTypography.body)
                    }
                    Spacer()
                }
                .foregroundStyle(Color.ruulSemanticError)
                .padding(.horizontal, RuulSpacing.s4)
                .padding(.vertical, RuulSpacing.s4)
                .background(
                    RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                        .fill(Color.ruulBackgroundElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                        .stroke(Color.ruulBorderSubtle, lineWidth: 1)
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
            .padding(.leading, RuulSpacing.s1)
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
        } catch {
            log.warning("members load failed: \(error.localizedDescription)")
        }
    }

    private func leaveGroup() async {
        guard !isLeaving else { return }
        isLeaving = true
        leaveError = nil
        defer { Task { @MainActor in isLeaving = false } }
        do {
            try await app.groupsRepo.leave(group.id)
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
