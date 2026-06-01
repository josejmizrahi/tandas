import Foundation
import Observation

/// `@MainActor` store for the Members surface (Primitiva 2 boundary).
/// Backed by `CanonicalMembersRepository.membershipBoundary(...)` —
/// the list mixes real memberships with pending invites, distinguished
/// by `MembershipBoundaryItem.kind`. Invites route through
/// `invite_member` (wrapped by the same repo); after a successful
/// invite the store refreshes so the new pending row appears.
///
/// Foundation scope: no admin actions, no role editing, no revoke
/// invite, no realtime.
@MainActor
@Observable
public final class MembersStore {

    // MARK: - State

    /// Canonical list, one row per "person currently related to the
    /// group" (membership or pending invite). Renamed from `members`
    /// in slice 8 — previews/tests still seed via the back-compat init.
    public private(set) var items: [MembershipBoundaryItem]
    public var phase: StorePhase = .idle
    public var searchText: String = ""

    /// D.22 — last governance outcome from saveStateDraft (ban/remove).
    /// `.decisionOpened` ⇒ a vote was created; UI shows alert + keeps the
    /// member visible. `.directAllowed` ⇒ founder override or non-terminal
    /// state. Cleared via `clearGovernanceOutcome()` once consumed.
    public private(set) var lastGovernanceOutcome: ActionOutcome?

    // MARK: - Invite form state

    public var isInviteSheetPresented: Bool = false
    public var inviteEmail: String = ""
    public var invitePhone: String = ""
    public var inviteMessage: String = ""
    public var inviteMembershipType: MembershipType = .member
    public private(set) var errorMessage: String?

    // MARK: - Dependencies

    private let repository: CanonicalMembersRepository?
    private var loadedGroupId: UUID?

    public init(repository: CanonicalMembersRepository) {
        self.repository = repository
        self.items = []
    }

    /// Preview/testing initialiser — seeds the store directly with
    /// boundary fixtures so SwiftUI previews and store tests don't
    /// have to spin up a repo.
    public init(initialItems: [MembershipBoundaryItem] = []) {
        self.repository = nil
        self.items = initialItems
        if !initialItems.isEmpty { self.phase = .loaded }
    }

    /// Back-compat seed for callers (mostly tests) still expressing
    /// state in terms of `MemberListItem`. Each membership-shaped
    /// fixture is wrapped as a `.membership` boundary row.
    public init(initialMembers: [MemberListItem]) {
        self.repository = nil
        self.items = initialMembers.map { m in
            MembershipBoundaryItem(
                id: m.id,
                kind: .membership,
                membershipId: m.id,
                inviteId: nil,
                userId: m.userId,
                displayName: m.displayName,
                username: nil,
                avatarURL: m.avatarURL,
                status: m.status,
                membershipType: m.membershipType,
                roleNames: m.roleNames,
                joinedAt: m.joinedAt,
                invitedAt: nil,
                isCurrentUser: m.isCurrentUser
            )
        }
        if !items.isEmpty { self.phase = .loaded }
    }

    // MARK: - Derived state

    /// Items filtered by `searchText`. Matches displayName, username,
    /// and any role name (case- and diacritic-insensitive). Invite
    /// rows whose `displayName` is the invite email/phone are
    /// matchable too because they go through the same path.
    public var filteredItems: [MembershipBoundaryItem] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return items.filter { item in
            if item.displayName.range(of: trimmed, options: opts) != nil { return true }
            if let u = item.username, u.range(of: trimmed, options: opts) != nil { return true }
            return item.roleNames.contains { $0.range(of: trimmed, options: opts) != nil }
        }
    }

    public var sections: [MemberSection] {
        var byKind: [MemberSectionKind: [MembershipBoundaryItem]] = [:]
        for item in filteredItems {
            byKind[Self.sectionKind(for: item), default: []].append(item)
        }
        return MemberSectionKind.renderOrder.compactMap { kind in
            guard let bucket = byKind[kind], !bucket.isEmpty else { return nil }
            return MemberSection(kind: kind, members: bucket)
        }
    }

    /// Back-compat read-only view: only the `.membership` rows
    /// projected back to the legacy `MemberListItem` shape, for any
    /// caller that still consumes that surface.
    public var members: [MemberListItem] {
        items.filter { $0.kind == .membership }.map { $0.asMemberListItem }
    }

    public var canSubmitInvite: Bool {
        let email = inviteEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = invitePhone.trimmingCharacters(in: .whitespacesAndNewlines)
        return !email.isEmpty || !phone.isEmpty
    }

    // MARK: - Intents

    public func refresh(groupId: UUID) async {
        guard let repository else {
            phase = .loaded
            loadedGroupId = groupId
            return
        }
        if items.isEmpty || loadedGroupId != groupId {
            phase = .loading
        }
        do {
            let fetched = try await repository.membershipBoundary(groupId: groupId)
            items = fetched
            phase = .loaded
            loadedGroupId = groupId
            errorMessage = nil
        } catch {
            let message = UserFacingError.from(error).message
            errorMessage = message
            phase = .failed(message: message)
        }
    }

    public func refreshIfNeeded(groupId: UUID) async {
        if loadedGroupId == groupId, !items.isEmpty {
            if case .idle = phase { phase = .loaded }
            return
        }
        await refresh(groupId: groupId)
    }

    /// V3-INV: returns the freshly created invite (with its shareable
    /// code) so the calling sheet can route the user into share/copy
    /// flows. Returns nil if the form is invalid or the repository was
    /// not configured (preview mode).
    public func inviteMember(groupId: UUID) async -> InviteCreated? {
        guard canSubmitInvite else { return nil }
        guard let repository else {
            clearInviteForm()
            return nil
        }
        let email = inviteEmail.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        let phone = invitePhone.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        let message = inviteMessage.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        do {
            let created = try await repository.inviteMember(
                groupId: groupId,
                email: email,
                phone: phone,
                membershipType: inviteMembershipType,
                message: message
            )
            clearInviteForm()
            await refresh(groupId: groupId)
            return created
        } catch {
            errorMessage = UserFacingError.from(error).message
            return nil
        }
    }

    /// V3-INV: cancel a pending invitation. Refreshes the boundary list
    /// on success so the revoked row drops out of `items`. Returns false
    /// on server error (typically: invite has open obligations).
    public func revokeInvite(inviteId: UUID, groupId: UUID, reason: String? = nil) async -> Bool {
        guard let repository else { return true }
        do {
            try await repository.revokeInvite(inviteId: inviteId, reason: reason)
            await refresh(groupId: groupId)
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func clearInviteForm() {
        inviteEmail = ""
        invitePhone = ""
        inviteMessage = ""
        inviteMembershipType = .member
        errorMessage = nil
    }

    public func clearError() { errorMessage = nil }

    // MARK: - V3-D.20 — Approve membership request

    /// `approve_membership_request(p_membership_id)`. iOS-side wrapper;
    /// refresca el boundary on success.
    @discardableResult
    public func approveRequest(membershipId: UUID, groupId: UUID) async -> Bool {
        guard let repository else { return false }
        do {
            _ = try await repository.approveRequest(membershipId: membershipId)
            await refresh(groupId: groupId)
            errorMessage = nil
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    /// D.24 — direct `set_membership_state` call without going through the
    /// state sheet draft. Used by the inline "Rechazar" pill in the
    /// requests cluster. Backend gates per target state (left requires
    /// `members.remove` OR self), so admins can reject and the requester
    /// themselves can withdraw via the same path.
    @discardableResult
    public func rejectRequest(
        membershipId: UUID,
        groupId: UUID,
        reason: String? = "Solicitud rechazada"
    ) async -> Bool {
        guard let repository else { return false }
        do {
            try await repository.setMembershipState(
                membershipId: membershipId,
                newState: .left,
                reason: reason,
                until: nil
            )
            await refresh(groupId: groupId)
            errorMessage = nil
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    // MARK: - Membership state (Primitiva 2)

    /// Drives `MembershipStateSheet`. Caller decides the target state
    /// before opening (Suspender → `.suspended`, Reactivar → `.active`,
    /// Expulsar → `.banned`).
    public var isStateSheetPresented: Bool = false
    public var stateDraftMembershipId: UUID?
    public var stateDraftTargetState: MembershipStatus = .active
    public var stateDraftReason: String = ""
    public var stateDraftHasUntil: Bool = false
    public var stateDraftUntil: Date = Date().addingTimeInterval(7 * 24 * 3600)

    public func beginChangingState(
        membershipId: UUID,
        target: MembershipStatus,
        prefillReason: String? = nil
    ) {
        stateDraftMembershipId = membershipId
        stateDraftTargetState = target
        stateDraftReason = prefillReason ?? ""
        stateDraftHasUntil = false
        stateDraftUntil = Date().addingTimeInterval(7 * 24 * 3600)
        errorMessage = nil
        isStateSheetPresented = true
    }

    public var canSaveStateDraft: Bool {
        guard stateDraftMembershipId != nil else { return false }
        // Expulsar / Suspender requieren razón mínima; Reactivar no.
        if stateDraftTargetState != .active {
            let trimmed = stateDraftReason.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty
        }
        return true
    }

    @discardableResult
    public func saveStateDraft(groupId: UUID) async -> Bool {
        guard let repository, let membershipId = stateDraftMembershipId else {
            errorMessage = "No hay miembro seleccionado."
            return false
        }
        let trimmedReason = stateDraftReason
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
        let until = (stateDraftTargetState == .suspended && stateDraftHasUntil)
            ? stateDraftUntil
            : nil
        do {
            let outcome = try await repository.setMembershipStateViaGovernance(
                groupId: groupId,
                membershipId: membershipId,
                newState: stateDraftTargetState,
                reason: trimmedReason,
                until: until
            )
            lastGovernanceOutcome = outcome
            switch outcome {
            case .directAllowed:
                await refresh(groupId: groupId)
                isStateSheetPresented = false
                stateDraftMembershipId = nil
                stateDraftReason = ""
                stateDraftHasUntil = false
                return true
            case .decisionOpened:
                // Decision opened — close sheet but keep member visible.
                isStateSheetPresented = false
                stateDraftMembershipId = nil
                stateDraftReason = ""
                stateDraftHasUntil = false
                return true
            case .denied(let reason, let missingPermission):
                errorMessage = missingPermission.map { "Falta permiso: \($0)" } ?? reason
                return false
            case .unsupported(let reason, _):
                errorMessage = "Acción no soportada (\(reason))"
                return false
            case .failed(let reason, let message):
                errorMessage = message ?? reason
                return false
            }
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    /// Clears `lastGovernanceOutcome` after the UI has consumed it.
    public func clearGovernanceOutcome() {
        lastGovernanceOutcome = nil
    }

    // MARK: - Section routing

    private static func sectionKind(for item: MembershipBoundaryItem) -> MemberSectionKind {
        if item.isCurrentUser { return .currentUser }
        switch item.kind {
        case .invite:
            return .invited
        case .membership:
            switch item.status {
            case .active:
                return item.membershipType == .provisional ? .provisional : .active
            case .requested:
                // D.24: requested memberships get their own top-of-list
                // cluster so admins see pending join requests immediately.
                return .requested
            case .invited:
                return .invited
            case .paused, .suspended, .removed, .banned, .left:
                return .suspended
            }
        }
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
