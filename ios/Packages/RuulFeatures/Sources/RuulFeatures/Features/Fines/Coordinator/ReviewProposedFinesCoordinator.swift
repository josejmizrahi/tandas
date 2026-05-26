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

    /// Beta 1 W3 E-3.1: multi-device sync. Listens for `fines` changes
    /// and triggers a refresh. nil in preview/mock.
    // Swift 6: deinit is nonisolated. Task is Sendable; the
    // nonisolated(unsafe) annotation asserts the property is only mutated
    // inside the main-actor-isolated init.
    nonisolated(unsafe) private var changeFeedTask: Task<Void, Never>?

    public init(
        event: Event,
        fineRepo: any FineRepository,
        changeFeed: (any MultiDeviceChangeFeed)? = nil
    ) {
        self.event = event
        self.fineRepo = fineRepo
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
            // 2026-05-25 founder debug: surface raw error detail
            // alongside the user-friendly translation. The server's
            // `raise exception 'only host or admin can officialize'`
            // (mig 00155) was getting collapsed into a generic
            // "Algo salió mal" by `ruulUserMessage`, hiding the
            // actual cause. Verbose form lets the founder share what
            // failed; safe to keep — error is selectable text in the
            // UI banner.
            let detail = "\(type(of: error)): \(error)"
            log.warning("officialize failed fineId=\(fineId.uuidString) error=\(detail)")
            self.error = composeMutationError(error: error, detail: detail)
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
            let detail = "\(type(of: error)): \(error)"
            log.warning("void failed fineId=\(fineId.uuidString) error=\(detail)")
            self.error = composeMutationError(error: error, detail: detail)
        }
    }

    /// Combines the Spanish-MX user-facing message with the raw error
    /// detail so the banner shows both. Banner is `textSelection(.enabled)`
    /// in the view so founders can copy the detail when filing bugs.
    private func composeMutationError(error: Error, detail: String) -> String {
        let userMessage = error.ruulUserMessage
        // If the user message is the generic fallback, prepend a
        // permission-specific hint when the raw error mentions "host"
        // or "admin" — that's by far the most common officialize/void
        // failure mode (RPC permission gate per mig 00155 / 00273).
        let lower = detail.lowercased()
        if lower.contains("only host") || lower.contains("only admin")
            || lower.contains("host or admin") {
            return "Solo el host del evento o un admin pueden hacer esto.\n\nDetalle: \(detail)"
        }
        return "\(userMessage)\n\nDetalle: \(detail)"
    }

    private func replaceLocal(_ fine: Fine) {
        if let idx = fines.firstIndex(where: { $0.id == fine.id }) {
            fines[idx] = fine
        }
    }

    public var proposed: [Fine] { fines.filter { $0.status == .proposed } }
    public var resolved: [Fine] { fines.filter { $0.status != .proposed } }
}
