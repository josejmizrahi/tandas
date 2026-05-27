import Foundation
import Observation

/// `@MainActor` store for Primitiva 5 (Resources). Holds active
/// envelope rows + the create draft. Foundation surface: no detail
/// screen, no edit-existing-resource flow, no subtype-specific
/// fields.
@MainActor
@Observable
public final class ResourcesStore {
    public private(set) var resources: [GroupResource] = []
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?

    public var isCreatePresented: Bool = false
    public var draftName: String = ""
    public var draftDescription: String = ""
    public var draftType: GroupResourceType = .other
    public var draftVisibility: ResourceVisibility = .members
    public var draftOwnershipKind: ResourceOwnershipKind = .group
    public var draftOwnerMembershipId: UUID?
    public var draftCustodianMembershipId: UUID?

    private let repository: CanonicalResourcesRepository
    private var loadedGroupId: UUID?

    public init(repository: CanonicalResourcesRepository) {
        self.repository = repository
    }

    // MARK: - Derived state

    public var hasResources: Bool { !resources.isEmpty }

    /// Active rows grouped by type, preserving the backend order
    /// inside each bucket.
    public var resourcesByType: [GroupResourceType: [GroupResource]] {
        Dictionary(grouping: resources, by: \.resourceType)
    }

    /// Top 3 rows for the GroupHome card.
    public var topResources: [GroupResource] { Array(resources.prefix(3)) }

    public var canSaveDraft: Bool {
        !draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Intents

    public func refresh(groupId: UUID) async {
        if resources.isEmpty || loadedGroupId != groupId {
            phase = .loading
        }
        do {
            let fetched = try await repository.activeResources(groupId: groupId)
            resources = fetched
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
        if loadedGroupId == groupId, !resources.isEmpty {
            if case .idle = phase { phase = .loaded }
            return
        }
        await refresh(groupId: groupId)
    }

    /// Opens the create sheet with a fresh draft.
    public func beginCreating(type: GroupResourceType? = nil) {
        draftName = ""
        draftDescription = ""
        draftType = type ?? .other
        draftVisibility = .members
        draftOwnershipKind = .group
        draftOwnerMembershipId = nil
        draftCustodianMembershipId = nil
        errorMessage = nil
        isCreatePresented = true
    }

    @discardableResult
    public func createDraft(groupId: UUID) async -> Bool {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            errorMessage = "Ponle un nombre al recurso."
            return false
        }
        do {
            _ = try await repository.createResource(
                groupId: groupId,
                type: draftType,
                name: name,
                description: draftDescription,
                visibility: draftVisibility,
                ownershipKind: draftOwnershipKind,
                ownerMembershipId: draftOwnerMembershipId,
                custodianMembershipId: draftCustodianMembershipId
            )
            // Refetch so we get the canonical sort + the wire shape
            // from `group_resources_active` (rather than a one-off
            // local insert).
            await refresh(groupId: groupId)
            isCreatePresented = false
            clearDraft()
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    @discardableResult
    public func archive(resourceId: UUID, reason: String? = nil, groupId: UUID) async -> Bool {
        do {
            try await repository.archiveResource(resourceId: resourceId, reason: reason)
            resources.removeAll(where: { $0.id == resourceId })
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func clearDraft() {
        draftName = ""
        draftDescription = ""
        draftType = .other
        draftVisibility = .members
        draftOwnershipKind = .group
        draftOwnerMembershipId = nil
        draftCustodianMembershipId = nil
        errorMessage = nil
    }

    public func clearError() { errorMessage = nil }
}
