import Foundation
import OSLog
import RuulUI
import RuulCore

@Observable @MainActor
public final class MyFinesCoordinator {
    public private(set) var fines: [Fine] = []
    public private(set) var groupsById: [UUID: Group] = [:]
    public private(set) var isLoading: Bool = false
    public private(set) var error: CoordinatorError?

    private let userId: UUID
    private let fineRepo: any FineRepository
    private let groupsRepo: (any GroupsRepository)?
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "fines.mine")

    public init(
        userId: UUID,
        fineRepo: any FineRepository,
        groupsRepo: (any GroupsRepository)? = nil
    ) {
        self.userId = userId
        self.fineRepo = fineRepo
        self.groupsRepo = groupsRepo
    }

    public func refresh() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            async let finesTask = fineRepo.myFines(userId: userId)
            async let groupsTask: [Group] = {
                guard let repo = groupsRepo else { return [] }
                return (try? await repo.listMine()) ?? []
            }()
            let (loadedFines, loadedGroups) = try await (finesTask, groupsTask)
            self.fines = loadedFines
            self.groupsById = Dictionary(uniqueKeysWithValues: loadedGroups.map { ($0.id, $0) })
        } catch {
            log.warning("myFines load failed: \(error.localizedDescription)")
            self.error = CoordinatorError.from(error, fallback: "No pudimos cargar tus multas")
        }
    }

    public func clearError() { error = nil }

    public func groupName(for fine: Fine) -> String? {
        groupsById[fine.groupId]?.name
    }

    public var pending: [Fine] {
        fines.filter { $0.status == .proposed || $0.status == .officialized || $0.status == .inAppeal }
    }

    public var resolved: [Fine] {
        fines.filter { $0.status == .paid || $0.status == .voided }
    }

    public var totalOutstanding: Decimal {
        pending
            .filter { $0.status == .officialized }
            .reduce(Decimal(0)) { $0 + $1.amount }
    }
}
