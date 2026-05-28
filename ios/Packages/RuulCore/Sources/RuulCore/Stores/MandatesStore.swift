import Foundation
import Observation

/// `@MainActor` store for Primitiva 23 (Mandatos). Caches active
/// mandates per group + drives the `GrantMandateSheet` form via a
/// draft. Revoke is optimistic locally.
@MainActor
@Observable
public final class MandatesStore {
    public private(set) var mandates: [GroupMandate] = []
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?

    /// Drives the `GrantMandateSheet`.
    public var isGrantPresented: Bool = false
    public var draftRepresentativeMembershipId: UUID?
    public var draftType: MandateType = .represent
    public var draftPrincipalType: MandatePrincipalType = .group
    public var draftEndsAt: Date?
    public var draftHasEndDate: Bool = false

    private let repository: CanonicalMandatesRepository
    private var loadedGroupId: UUID?

    public init(repository: CanonicalMandatesRepository) {
        self.repository = repository
    }

    // MARK: - Derived

    public var hasMandates: Bool { !mandates.isEmpty }

    public var mandatesByType: [MandateType: [GroupMandate]] {
        Dictionary(grouping: mandates, by: \.type)
    }

    public var canSaveDraft: Bool { draftRepresentativeMembershipId != nil }

    // MARK: - Intents

    public func refresh(groupId: UUID) async {
        if mandates.isEmpty || loadedGroupId != groupId {
            phase = .loading
        }
        do {
            let fetched = try await repository.activeMandates(groupId: groupId)
            mandates = fetched
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
        if loadedGroupId == groupId, !mandates.isEmpty {
            if case .idle = phase { phase = .loaded }
            return
        }
        await refresh(groupId: groupId)
    }

    public func beginGranting(defaultRepresentative: UUID? = nil) {
        draftRepresentativeMembershipId = defaultRepresentative
        draftType = .represent
        draftPrincipalType = .group
        draftEndsAt = nil
        draftHasEndDate = false
        errorMessage = nil
        isGrantPresented = true
    }

    @discardableResult
    public func saveDraft(groupId: UUID) async -> Bool {
        guard let rep = draftRepresentativeMembershipId else {
            errorMessage = "Selecciona quién representa."
            return false
        }
        let endsAt = draftHasEndDate ? draftEndsAt : nil
        if let endsAt, endsAt <= Date() {
            errorMessage = "La fecha de vencimiento debe ser futura."
            return false
        }
        do {
            _ = try await repository.grant(
                groupId: groupId,
                representativeMembershipId: rep,
                type: draftType,
                principalType: draftPrincipalType,
                principalId: nil,
                endsAt: endsAt
            )
            await refresh(groupId: groupId)
            isGrantPresented = false
            clearDraft()
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    @discardableResult
    public func revoke(mandateId: UUID, reason: String? = nil, groupId: UUID) async -> Bool {
        do {
            try await repository.revoke(mandateId: mandateId, reason: reason)
            mandates.removeAll { $0.id == mandateId }
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func clearDraft() {
        draftRepresentativeMembershipId = nil
        draftType = .represent
        draftPrincipalType = .group
        draftEndsAt = nil
        draftHasEndDate = false
        errorMessage = nil
    }

    public func clearError() { errorMessage = nil }
}
