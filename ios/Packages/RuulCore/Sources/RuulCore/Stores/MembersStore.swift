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

    public func inviteMember(groupId: UUID) async -> Bool {
        guard canSubmitInvite else { return false }
        guard let repository else {
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

    public func clearError() { errorMessage = nil }

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
            case .invited, .requested:
                return .invited
            case .suspended, .banned, .left:
                return .suspended
            }
        }
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
