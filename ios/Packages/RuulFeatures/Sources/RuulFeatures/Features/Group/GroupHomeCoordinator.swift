import Foundation
import Observation
import OSLog
import RuulCore

@Observable
@MainActor
public final class GroupHomeCoordinator {
    public let groupId: UUID
    private let groupsRepo: any GroupsRepository
    private let moduleRegistry: ModuleRegistry
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "group.home")

    public var group: Group?
    public var memberCount: Int = 0
    public var myRole: String?          // "founder" | "member" | "admin"
    public var activeModules: [GroupModule] = []
    public var isLoading: Bool = false
    public var error: CoordinatorError?

    public var isCurrentUserAdmin: Bool { myRole == "founder" }

    public init(
        groupId: UUID,
        groupsRepo: any GroupsRepository,
        moduleRegistry: ModuleRegistry = .v1Fallback
    ) {
        self.groupId = groupId
        self.groupsRepo = groupsRepo
        self.moduleRegistry = moduleRegistry
    }

    public func refresh() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let detail = try await groupsRepo.get(groupId)
            self.group = detail.group
            self.memberCount = detail.memberCount
            self.myRole = detail.myRole
            self.activeModules = resolveModules(slugs: detail.group.activeModules ?? [])
        } catch {
            log.warning("group home refresh failed: \(error.localizedDescription, privacy: .public)")
            self.error = CoordinatorError.from(error, fallback: "No pudimos cargar el grupo")
        }
    }

    public func clearError() { error = nil }

    private func resolveModules(slugs: [String]) -> [GroupModule] {
        slugs.compactMap { slug in moduleRegistry.modules.first(where: { $0.id == slug }) }
    }
}
