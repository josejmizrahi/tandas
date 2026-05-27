import Foundation
import RuulCore

enum ResourcesPreviewData {
    static let fund = GroupResource(
        id: UUID(), groupId: UUID(),
        resourceType: .fund,
        name: "Fondo del viaje",
        description: "Fondo común para gasolina y hospedaje.",
        visibility: .members,
        ownershipKind: .group
    )

    static let space = GroupResource(
        id: UUID(), groupId: UUID(),
        resourceType: .space,
        name: "Casa de Jose",
        description: "Donde nos juntamos los viernes.",
        visibility: .members,
        ownershipKind: .member
    )

    static let asset = GroupResource(
        id: UUID(), groupId: UUID(),
        resourceType: .asset,
        name: "Mesa de poker",
        description: nil,
        visibility: .members,
        ownershipKind: .group
    )

    static let document = GroupResource(
        id: UUID(), groupId: UUID(),
        resourceType: .document,
        name: "Acuerdos del grupo",
        description: "Notas escritas en Notion.",
        visibility: .private,
        ownershipKind: .group
    )

    static let all: [GroupResource] = [fund, space, asset, document]
}
