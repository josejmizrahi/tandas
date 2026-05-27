import Foundation
import Observation

/// `@MainActor` store for the Foundation readiness card. Holds the
/// last fetched `GroupFoundationStatus` plus phase/error so the View
/// can render loading/ready/needs-setup without flicker.
@MainActor
@Observable
public final class FoundationStatusStore {
    public private(set) var status: GroupFoundationStatus?
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?

    private let repository: CanonicalFoundationStatusRepository
    private var loadedGroupId: UUID?

    public init(repository: CanonicalFoundationStatusRepository) {
        self.repository = repository
    }

    // MARK: - Derived helpers

    public var isReady: Bool { status?.isReady ?? false }
    public var incompletePrimitives: [FoundationPrimitiveKind] {
        status?.incompletePrimitives ?? FoundationPrimitiveKind.displayOrder
    }
    public var completionRatio: Double { status?.completionRatio ?? 0 }
    public var completeCount: Int {
        FoundationPrimitiveKind.allCases.filter { status?.primitive(for: $0).isComplete == true }.count
    }

    public func primitive(for kind: FoundationPrimitiveKind) -> GroupFoundationPrimitive? {
        status?.primitive(for: kind)
    }

    // MARK: - Intents

    public func refresh(groupId: UUID) async {
        if status == nil || loadedGroupId != groupId {
            phase = .loading
        }
        do {
            status = try await repository.fetchGroupFoundationStatus(groupId: groupId)
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
        if loadedGroupId == groupId, status != nil {
            if case .idle = phase { phase = .loaded }
            return
        }
        await refresh(groupId: groupId)
    }

    public func clearError() { errorMessage = nil }
}
