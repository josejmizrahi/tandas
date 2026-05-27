import Foundation
import RuulCore

/// Preview fixtures for the rules surface.
enum RulesPreviewData {
    static let prohibition = GroupRule(
        id: UUID(), currentVersionId: UUID(), groupId: UUID(),
        title: "Sin celulares en la mesa",
        body: "Apaga el teléfono al sentarse. Solo emergencias.",
        ruleType: .prohibition, severity: 3,
        executionMode: .text, status: "active",
        effectiveFrom: Date(timeIntervalSinceNow: -86_400 * 3)
    )

    static let principle = GroupRule(
        id: UUID(), currentVersionId: UUID(), groupId: UUID(),
        title: "Llegar a tiempo",
        body: "El plan no espera. Si te atrasas, avisa.",
        ruleType: .principle, severity: 2,
        executionMode: .text, status: "active"
    )

    static let process = GroupRule(
        id: UUID(), currentVersionId: UUID(), groupId: UUID(),
        title: "Rotación de host",
        body: "Cada quien hostea una vez por mes en orden alfabético.",
        ruleType: .process, severity: 1,
        executionMode: .text, status: "active"
    )

    static let all: [GroupRule] = [prohibition, principle, process]
}
