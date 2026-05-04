import Foundation
import OSLog

@Observable @MainActor
final class RulesCoordinator {
    private(set) var rules: [GroupRule] = []
    private(set) var isLoading: Bool = false
    private(set) var error: String?

    let group: Group
    private let ruleRepo: any RuleRepository
    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "rules")

    init(group: Group, ruleRepo: any RuleRepository) {
        self.group = group
        self.ruleRepo = ruleRepo
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            // Server may return both legacy + platform rows for a group seeded
            // before Sprint 1b. Show only platform-shape rows (consequences
            // populated) — those are the ones the engine actually fires.
            let all = try await ruleRepo.list(groupId: group.id)
            rules = all.filter { !$0.consequences.isEmpty }
            if rules.isEmpty {
                // Fallback for very old groups without platform-shape rows.
                rules = all
            }
        } catch {
            log.warning("rules load failed: \(error.localizedDescription)")
            self.error = error.localizedDescription
        }
    }
}
