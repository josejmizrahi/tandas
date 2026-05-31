import Foundation
import Observation

/// 2-step Create flow state machine. Step 1 is the type picker (forces
/// the user to pick from the 18 canonical types before seeing per-type
/// fields); Step 2 is the common form.
public enum CreateResourceStep: String, Sendable, Hashable {
    case type
    case details
}

/// `@MainActor` store for Primitiva 5 (Resources). Holds active
/// envelope rows + the create draft. Foundation surface focuses on the
/// envelope: subtype-specific writes (assign custodian, lock fund, book
/// space, …) ship in Fase B/C with dedicated sheets.
@MainActor
@Observable
public final class ResourcesStore {
    public private(set) var resources: [GroupResource] = []
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?

    public var isCreatePresented: Bool = false

    /// 2-step Create flow: type picker → form. The store drives the
    /// step so the sheet can present either screen on open and the
    /// store decides what "Back" / "Continue" buttons do.
    public var createStep: CreateResourceStep = .type
    public var draftName: String = ""
    public var draftDescription: String = ""
    public var draftType: GroupResourceType = .fund
    public var draftVisibility: ResourceVisibility = .members
    public var draftOwnershipKind: ResourceOwnershipKind = .group
    public var draftOwnerMembershipId: UUID?

    /// Drives the `TransferOwnershipSheet` for an existing resource.
    public var isTransferPresented: Bool = false
    public var transferResourceId: UUID?
    public var transferKind: ResourceOwnershipKind = .group
    public var transferOwnerMembershipId: UUID?
    public var transferNote: String = ""

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

    /// Opens the create sheet with a fresh draft. When `type` is `nil`
    /// the flow starts on the type picker (Step 1); when provided we
    /// skip straight to the details form (Step 2).
    public func beginCreating(type: GroupResourceType? = nil) {
        draftName = ""
        draftDescription = ""
        draftType = type ?? .fund
        draftVisibility = .members
        draftOwnershipKind = .group
        draftOwnerMembershipId = nil
        createStep = (type == nil) ? .type : .details
        errorMessage = nil
        isCreatePresented = true
    }

    /// Step 1 → Step 2 of the Create flow.
    public func advanceFromTypePicker() {
        createStep = .details
        errorMessage = nil
    }

    /// Step 2 → Step 1 of the Create flow.
    public func returnToTypePicker() {
        createStep = .type
        errorMessage = nil
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
                ownerMembershipId: draftOwnerMembershipId
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
        draftType = .fund
        draftVisibility = .members
        draftOwnershipKind = .group
        draftOwnerMembershipId = nil
        createStep = .type
        errorMessage = nil
    }

    public func clearError() { errorMessage = nil }

    // MARK: - Transfer ownership

    public func beginTransferring(_ resource: GroupResource) {
        transferResourceId = resource.id
        transferKind = resource.ownershipKind
        transferOwnerMembershipId = resource.ownerMembershipId
        transferNote = ""
        errorMessage = nil
        isTransferPresented = true
    }

    public var canSaveTransfer: Bool {
        guard transferResourceId != nil else { return false }
        if transferKind == .member, transferOwnerMembershipId == nil { return false }
        return true
    }

    @discardableResult
    public func saveTransfer(groupId: UUID) async -> Bool {
        guard let resourceId = transferResourceId else {
            errorMessage = "No hay recurso seleccionado."
            return false
        }
        if transferKind == .member, transferOwnerMembershipId == nil {
            errorMessage = "Elige a quién pasa la propiedad."
            return false
        }
        do {
            try await repository.transferOwnership(
                resourceId: resourceId,
                ownershipKind: transferKind,
                ownerMembershipId: transferOwnerMembershipId,
                note: transferNote
            )
            await refresh(groupId: groupId)
            isTransferPresented = false
            transferResourceId = nil
            transferOwnerMembershipId = nil
            transferNote = ""
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }
}
