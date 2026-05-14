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
            let result = try await fineRepo.fines(forEventId: event.id)
            let statuses = result.map { $0.status.rawValue }.joined(separator: ",")
            log.info("review fines loaded eventId=\(self.event.id.uuidString) count=\(result.count) statuses=\(statuses)")
            fines = result
        } catch {
            let detail = "\(type(of: error)): \(error)"
            log.warning("review fines load failed eventId=\(self.event.id.uuidString) error=\(detail)")
            self.error = detail
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
            // W2-C2: translate to Spanish-MX so PostgREST/JWT/network
            // messages don't leak straight into the inbox banner.
            self.error = error.ruulUserMessage
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
            self.error = error.ruulUserMessage
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
