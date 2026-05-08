import Foundation
import OSLog
import RuulUI
import RuulCore

@Observable @MainActor
public final class ReviewProposedFinesCoordinator {
    public let event: Event
    public private(set) var fines: [Fine] = []
    public private(set) var isLoading: Bool = false
    public private(set) var isMutating: Bool = false
    public private(set) var error: String?

    private let fineRepo: any FineRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "fines.review")

    public init(event: Event, fineRepo: any FineRepository) {
        self.event = event
        self.fineRepo = fineRepo
    }

    public func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            fines = try await fineRepo.fines(forEventId: event.id)
        } catch {
            log.warning("review fines load failed: \(error.localizedDescription)")
            self.error = error.localizedDescription
        }
    }

    public func officializeAll() async {
        for fine in fines where fine.status == .proposed {
            await officialize(fineId: fine.id)
        }
    }

    public func officialize(fineId: UUID) async {
        guard !isMutating else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            let updated = try await fineRepo.officialize(fineId: fineId)
            replaceLocal(updated)
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func void(fineId: UUID, reason: String?) async {
        guard !isMutating else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            let updated = try await fineRepo.void(fineId: fineId, reason: reason)
            replaceLocal(updated)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func replaceLocal(_ fine: Fine) {
        if let idx = fines.firstIndex(where: { $0.id == fine.id }) {
            fines[idx] = fine
        }
    }

    public var proposed: [Fine] { fines.filter { $0.status == .proposed } }
    public var resolved: [Fine] { fines.filter { $0.status != .proposed } }
}
