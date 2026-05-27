import Foundation
import Observation

/// `@MainActor` store for the Members surface. Slice 6 ships only the
/// UI scaffolding — `refresh` / `inviteMember` are intentional no-op
/// stubs awaiting `CanonicalMembersRepository` (next slice). The
/// observable state is real and drives the SwiftUI bindings (search,
/// invite form, sheet presentation) end-to-end.
///
/// Keeps the legacy `LoadPhase<Value>` decoupled — Foundation stores
/// use the simpler `StorePhase` introduced in slice 2.
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

    public init(initialMembers: [MemberListItem] = []) {
        self.members = initialMembers
        if !initialMembers.isEmpty {
            self.phase = .loaded
        }
    }

    // MARK: - Derived state

    /// `members` filtered by `searchText`. Empty query → unmodified.
    /// Case- and diacritic-insensitive substring match on `displayName`.
    public var filteredMembers: [MemberListItem] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return members }
        return members.filter {
            $0.displayName.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// Bucketed view of `filteredMembers`, ordered per
    /// `MemberSectionKind.renderOrder`. Empty kinds are skipped so the
    /// caller can iterate sections directly.
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

    /// At least one of email or phone must be present; whitespace-only
    /// values don't count.
    public var canSubmitInvite: Bool {
        let email = inviteEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = invitePhone.trimmingCharacters(in: .whitespacesAndNewlines)
        return !email.isEmpty || !phone.isEmpty
    }

    // MARK: - Intents

    /// Forces a reload. Real backend wiring lands when
    /// `CanonicalMembersRepository` ships; for now this is a no-op that
    /// preserves the existing `members` array and only nudges `phase`
    /// for visual feedback.
    public func refresh(groupId: UUID) async {
        if members.isEmpty { phase = .loading }
        // TODO: replace with await repository.listMembers(groupId:) once
        // the canonical members RPC lands.
        phase = .loaded
    }

    /// Calls `refresh` only when the store has never loaded. Use this
    /// from `.task` modifiers to avoid stomping a freshly loaded list.
    public func refreshIfNeeded(groupId: UUID) async {
        if case .idle = phase {
            await refresh(groupId: groupId)
        }
    }

    /// Stubbed invite submission. Returns true and clears the form so
    /// the sheet UX works end-to-end against preview data; the real
    /// implementation will route through `CanonicalInviteRepository`.
    public func inviteMember(groupId: UUID) async -> Bool {
        guard canSubmitInvite else { return false }
        // TODO: await CanonicalInviteRepository.inviteMember(...)
        clearInviteForm()
        return true
    }

    public func clearInviteForm() {
        inviteEmail = ""
        invitePhone = ""
        inviteMessage = ""
        inviteMembershipType = .member
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
