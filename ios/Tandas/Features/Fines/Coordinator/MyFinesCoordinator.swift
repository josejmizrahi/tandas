import Foundation
import OSLog

@Observable @MainActor
final class MyFinesCoordinator {
    private(set) var fines: [Fine] = []
    private(set) var groupsById: [UUID: Group] = [:]
    private(set) var isLoading: Bool = false
    private(set) var error: String?

    private let userId: UUID
    private let fineRepo: any FineRepository
    private let groupsRepo: (any GroupsRepository)?
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "fines.mine")

    init(
        userId: UUID,
        fineRepo: any FineRepository,
        groupsRepo: (any GroupsRepository)? = nil
    ) {
        self.userId = userId
        self.fineRepo = fineRepo
        self.groupsRepo = groupsRepo
    }

    func refresh() async {
        isLoading = true
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
            self.error = error.localizedDescription
        }
    }

    func groupName(for fine: Fine) -> String? {
        groupsById[fine.groupId]?.name
    }

    var pending: [Fine] {
        fines.filter { $0.status == .proposed || $0.status == .officialized || $0.status == .inAppeal }
    }

    var resolved: [Fine] {
        fines.filter { $0.status == .paid || $0.status == .voided }
    }

    var totalOutstanding: Decimal {
        pending
            .filter { $0.status == .officialized }
            .reduce(Decimal(0)) { $0 + $1.amount }
    }
}
