import Foundation
import RuulCore

enum ResourcesPreviewData {
    static let fund = GroupResource(
        id: UUID(), groupId: UUID(),
        resourceType: .fund,
        name: "Fondo del viaje",
        description: "Fondo común para gasolina y hospedaje.",
        visibility: .members,
        ownershipKind: .group,
        metadata: ["currency": .string("MXN")]
    )

    static let space = GroupResource(
        id: UUID(), groupId: UUID(),
        resourceType: .space,
        name: "Casa de Jose",
        description: "Donde nos juntamos los viernes.",
        visibility: .members,
        ownershipKind: .member,
        metadata: [
            "address":  .string("Av. de los Insurgentes 123"),
            "capacity": .number(8)
        ]
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
        ownershipKind: .group,
        metadata: ["url": .string("https://notion.so/acuerdos")]
    )

    static let vehicle = GroupResource(
        id: UUID(), groupId: UUID(),
        resourceType: .vehicle,
        name: "Van del grupo",
        description: "Para viajes largos.",
        visibility: .members,
        ownershipKind: .shared,
        metadata: [
            "make":    .string("Volkswagen"),
            "model":   .string("Transporter"),
            "plate":   .string("XYZ-123"),
            "mileage": .number(54_320)
        ]
    )

    static let inventory = GroupResource(
        id: UUID(), groupId: UUID(),
        resourceType: .inventory,
        name: "Cervezas de la fiesta",
        description: nil,
        visibility: .members,
        ownershipKind: .group,
        metadata: [
            "quantity":  .number(48),
            "threshold": .number(12),
            "unit":      .string("latas")
        ]
    )

    static let all: [GroupResource] = [
        fund, space, asset, document, vehicle, inventory
    ]
}
