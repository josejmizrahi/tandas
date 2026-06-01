import Foundation
import Observation

/// V3 D.24 P12B-1 — `@MainActor` store que cachea el payload de
/// `group_home_summary(p_group_id)`. La vista `GroupHomeFeedView` lo lee
/// como fuente principal de permisos + counts + recent_activity; los
/// clusters específicos (decisions/deudas/dinero/recursos) siguen
/// consumiendo sus stores legacy hasta P12B-2/3/4.
///
/// Fallback semantics: si la RPC falla, `summary=nil` queda y la vista
/// debe degradarse al path legacy (fetches individuales). El error queda
/// en `errorMessage` para que la vista pueda log/debug.
@MainActor
@Observable
public final class GroupHomeSummaryStore {
    public private(set) var summary: GroupHomeSummary?
    public private(set) var phase: StorePhase = .idle
    public private(set) var errorMessage: String?
    public private(set) var lastLoadedGroupId: UUID?

    private let repository: CanonicalGroupRepository

    public init(repository: CanonicalGroupRepository) {
        self.repository = repository
    }

    /// Loads the summary. Doesn't throw — view degrades to legacy if nil.
    public func load(groupId: UUID) async {
        phase = .loading
        do {
            summary = try await repository.homeSummary(groupId: groupId)
            phase = .loaded
            lastLoadedGroupId = groupId
            errorMessage = nil
        } catch {
            let message = UserFacingError.from(error).message
            errorMessage = message
            phase = .failed(message: message)
            // Mantenemos summary previo si lo había; la vista decide.
        }
    }

    /// Best-effort refresh para `.refreshable`. Errors no rompen la UI.
    public func refresh(groupId: UUID) async {
        await load(groupId: groupId)
    }

    public func clear() {
        summary = nil
        phase = .idle
        errorMessage = nil
        lastLoadedGroupId = nil
    }
}
