import Foundation
import Observation

/// `@MainActor` store for Primitiva 20 (Culture). Holds active norms
/// per group + drives the `EditCulturalNormView` propose form via a
/// draft.
@MainActor
@Observable
public final class CulturalNormsStore {
    public private(set) var norms: [GroupCulturalNorm] = []
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?

    /// Drives the `EditCulturalNormView` sheet.
    public var isCreatePresented: Bool = false
    public var draftType: CulturalNormType = .value
    public var draftTitle: String = ""
    public var draftBody: String = ""
    public var draftVisibility: CulturalNormVisibility = .members

    private let repository: CanonicalCulturalNormsRepository
    private var loadedGroupId: UUID?

    public init(repository: CanonicalCulturalNormsRepository) {
        self.repository = repository
    }

    // MARK: - Derived

    public var hasNorms: Bool { !norms.isEmpty }
    public var normsByType: [CulturalNormType: [GroupCulturalNorm]] {
        Dictionary(grouping: norms, by: \.type)
    }

    public var canSaveDraft: Bool {
        !draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Intents

    public func refresh(groupId: UUID) async {
        if norms.isEmpty || loadedGroupId != groupId {
            phase = .loading
        }
        do {
            let fetched = try await repository.activeNorms(groupId: groupId)
            norms = fetched
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
        if loadedGroupId == groupId, !norms.isEmpty {
            if case .idle = phase { phase = .loaded }
            return
        }
        await refresh(groupId: groupId)
    }

    public func beginCreating(type: CulturalNormType? = nil) {
        draftType = type ?? .value
        draftTitle = ""
        draftBody = ""
        draftVisibility = .members
        errorMessage = nil
        isCreatePresented = true
    }

    @discardableResult
    public func saveDraft(groupId: UUID) async -> Bool {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            errorMessage = "Escribe un título."
            return false
        }
        do {
            _ = try await repository.proposeNorm(
                groupId: groupId,
                type: draftType,
                title: title,
                body: draftBody,
                visibility: draftVisibility
            )
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
    public func endorse(normId: UUID, groupId: UUID) async -> Bool {
        do {
            let newCount = try await repository.endorse(normId: normId)
            // Patch the local row so the count flips without a refetch
            // round-trip; backend authority resolves on next refresh.
            if let idx = norms.firstIndex(where: { $0.id == normId }) {
                let n = norms[idx]
                norms[idx] = GroupCulturalNorm(
                    id: n.id,
                    groupId: n.groupId,
                    type: n.type,
                    title: n.title,
                    body: n.body,
                    visibility: n.visibility,
                    status: n.status == .proposed ? .endorsed : n.status,
                    endorsedCount: newCount,
                    proposedBy: n.proposedBy,
                    proposedByDisplayName: n.proposedByDisplayName,
                    createdAt: n.createdAt,
                    updatedAt: n.updatedAt
                )
            }
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            // Stale local state — refresh so the UI reconciles.
            await refresh(groupId: groupId)
            return false
        }
    }

    @discardableResult
    public func retire(normId: UUID, reason: String? = nil, groupId: UUID) async -> Bool {
        do {
            try await repository.retire(normId: normId, reason: reason)
            norms.removeAll { $0.id == normId }
            return true
        } catch {
            errorMessage = UserFacingError.from(error).message
            return false
        }
    }

    public func clearDraft() {
        draftType = .value
        draftTitle = ""
        draftBody = ""
        draftVisibility = .members
        errorMessage = nil
    }

    public func clearError() { errorMessage = nil }
}
