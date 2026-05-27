import Foundation
import Observation

/// `@MainActor` store for the Members surface. Backed by
/// `CanonicalMembersRepository` — the list comes from the canonical
/// `group_members(p_group_id)` RPC and invites route through
/// `invite_member` (wrapped by the same repo).
///
/// Foundation scope: no admin actions, no role editing, no realtime.
/// The store keeps its own search/invite-form state so the Views stay
/// dumb.
@MainActor
@Observable
public final class MembersStore {

    // MARK: - State

    public private(set) var members: [MemberListItem]
    public var phase: StorePhase = .idle
    public var searchText: String = ""

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

    /// Production initialiser — injects a real repository.
    public init(repository: CanonicalMembersRepository) {
        self.repository = repository
        self.members = []
    }

    /// Preview/testing initialiser — seeds the store with stub rows so
    /// SwiftUI previews and unit tests don't have to spin up a repo.
    /// `refresh` becomes a no-op (just re-asserts `.loaded`) when no
    /// repository is wired.
    public init(initialMembers: [MemberListItem] = []) {
        self.repository = nil
        self.members = initialMembers
        if !initialMembers.isEmpty {
            self.phase = .loaded
        }
    }

    // MARK: - Derived state

    public var filteredMembers: [MemberListItem] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return members }
        return members.filter {
            $0.displayName.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    public var sections: [MemberSection] {
        var byKind: [MemberSectionKind: [MemberListItem]] = [:]
        for member in filteredMembers {
            byKind[Self.sectionKind(for: member), default: []].append(member)
        }
        return MemberSectionKind.renderOrder.compactMap { kind in
            guard let items = byKind[kind], !items.isEmpty else { return nil }
            return MemberSection(kind: kind, members: items)
        }
    }

    public var canSubmitInvite: Bool {
        let email = inviteEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = invitePhone.trimmingCharacters(in: .whitespacesAndNewlines)
        return !email.isEmpty || !phone.isEmpty
    }

    // MARK: - Intents

    /// Force-refetches the member list. Sets `.loading` only when there
    /// is no prior data so a re-pull doesn't flash the placeholder rows.
    public func refresh(groupId: UUID) async {
        guard let repository else {
            // Preview/test mode: just settle into .loaded without
            // touching the network.
            phase = .loaded
            loadedGroupId = groupId
            return
        }
        if members.isEmpty || loadedGroupId != groupId {
            phase = .loading
        }
        do {
            let fetched = try await repository.listMembers(groupId: groupId)
            members = fetched
            phase = .loaded
            loadedGroupId = groupId
            errorMessage = nil
        } catch {
            let message = UserFacingError.from(error).message
            errorMessage = message
            phase = .failed(message: message)
        }
    }

    /// `.task`-friendly loader: fetches the first time, no-ops on
    /// re-entry for the same group, refetches if the group changes.
    public func refreshIfNeeded(groupId: UUID) async {
        if loadedGroupId == groupId, !members.isEmpty {
            if case .idle = phase { phase = .loaded }
            return
        }
        await refresh(groupId: groupId)
    }

    /// Sends the invite via the repository. Returns `true` on success
    /// so the sheet can dismiss; on failure leaves the form intact and
    /// surfaces `errorMessage` for the View to display.
    public func inviteMember(groupId: UUID) async -> Bool {
        guard canSubmitInvite else { return false }
        guard let repository else {
            // Preview mode — pretend success so the sheet UX is testable.
            clearInviteForm()
            return true
        }
        let email = inviteEmail.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        let phone = invitePhone.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        let message = inviteMessage.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        do {
            _ = try await repository.inviteMember(
                groupId: groupId,
                email: email,
                phone: phone,
                membershipType: inviteMembershipType,
                message: message
            )
            clearInviteForm()
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

    public func clearError() {
        errorMessage = nil
    }

    // MARK: - Section routing

    private static func sectionKind(for member: MemberListItem) -> MemberSectionKind {
        if member.isCurrentUser { return .currentUser }
        switch member.status {
        case .active:
            return member.membershipType == .provisional ? .provisional : .active
        case .invited, .requested:
            return .invited
        case .suspended, .banned, .left:
            return .suspended
        }
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
