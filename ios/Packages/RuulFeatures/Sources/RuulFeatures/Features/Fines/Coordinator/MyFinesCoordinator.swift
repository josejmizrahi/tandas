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
    public private(set) var hasLoaded: Bool = false

    private let userId: UUID
    private let fineRepo: any FineRepository
    private let groupsRepo: (any GroupsRepository)?
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "fines.mine")

    /// Beta 1 W3 E-3.1: multi-device sync. Listens for `fines` changes
    /// and triggers a refresh. nil in preview/mock.
    // Swift 6: deinit is nonisolated. Task is Sendable; the
    // nonisolated(unsafe) annotation asserts the property is only mutated
    // inside the main-actor-isolated init.
    nonisolated(unsafe) private var changeFeedTask: Task<Void, Never>?

    public init(
        userId: UUID,
        fineRepo: any FineRepository,
        groupsRepo: (any GroupsRepository)? = nil,
        changeFeed: (any MultiDeviceChangeFeed)? = nil
    ) {
        self.userId = userId
        self.fineRepo = fineRepo
        self.groupsRepo = groupsRepo
        if let feed = changeFeed {
            self.changeFeedTask = Task { [weak self] in
                for await change in feed.changes {
                    if Task.isCancelled { return }
                    guard let self else { return }
                    if change.table == .fine {
                        await self.refresh()
                    }
                }
            }
        }
    }

    deinit { changeFeedTask?.cancel() }

    /// `LoadPhase` derivado para `AsyncContentView`. Distingue "primera
    /// carga vacía" (`.loading`) de "cargado sin multas" (`.empty`).
    public var phase: LoadPhase<[Fine]> {
        LoadPhase.fromCollection(
            value: fines,
            hasLoaded: hasLoaded,
            isLoading: isLoading,
            error: error
        )
    }

    public func refresh() async {
        isLoading = true
        error = nil
        defer {
            isLoading = false
            hasLoaded = true
        }
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
