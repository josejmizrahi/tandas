import Foundation

/// V3 Resources Deep — Fase A. Single source of truth for per-type
/// rendering metadata. Every `GroupResourceType` has a descriptor; UI,
/// stores, previews and tests should resolve via
/// `ResourceTypeRegistry.descriptor(for:)` (or
/// `GroupResourceType.descriptor`) rather than branching on the raw
/// enum value.
///
/// Fields:
/// - `label` / `subtitle` / `icon` — header + picker rendering.
/// - `subtypeTable` — `nil` for envelope-only types; otherwise the
///   `public.group_resource_*` table whose row augments the envelope.
/// - `coordinationBlocks` — set of `CoordinationBlockKind` cases the
///   layered detail should render for this type. Other blocks collapse.
/// - `supportsValuation/Custody/Booking/Assignment/Locking` — capability
///   bits used by per-type action strips (Fase B/C).
/// - `lifecycleEvents` — whitelisted `resource.*` event_types this type
///   emits via `record_resource_lifecycle_event`; drives the activity
///   filter + action menu in later phases.
/// - `metadataSchema` — declared keys + display labels for the
///   envelope's `metadata` jsonb. Used by row + detail surfaces to show
///   per-type fields without per-type decoding.
public struct ResourceTypeDescriptor: Sendable {
    public let type: GroupResourceType
    public let label: LocalizedStringResource
    public let subtitle: LocalizedStringResource
    public let icon: String
    public let subtypeTable: String?
    public let coordinationBlocks: Set<CoordinationBlockKind>
    public let supportsValuation: Bool
    public let supportsCustody: Bool
    public let supportsBooking: Bool
    public let supportsAssignment: Bool
    public let supportsLocking: Bool
    public let lifecycleEvents: [String]
    public let metadataSchema: [MetadataField]

    public init(
        type: GroupResourceType,
        label: LocalizedStringResource,
        subtitle: LocalizedStringResource,
        icon: String,
        subtypeTable: String?,
        coordinationBlocks: Set<CoordinationBlockKind>,
        supportsValuation: Bool = false,
        supportsCustody: Bool = false,
        supportsBooking: Bool = false,
        supportsAssignment: Bool = false,
        supportsLocking: Bool = false,
        lifecycleEvents: [String] = [],
        metadataSchema: [MetadataField] = []
    ) {
        self.type = type
        self.label = label
        self.subtitle = subtitle
        self.icon = icon
        self.subtypeTable = subtypeTable
        self.coordinationBlocks = coordinationBlocks
        self.supportsValuation = supportsValuation
        self.supportsCustody = supportsCustody
        self.supportsBooking = supportsBooking
        self.supportsAssignment = supportsAssignment
        self.supportsLocking = supportsLocking
        self.lifecycleEvents = lifecycleEvents
        self.metadataSchema = metadataSchema
    }
}

/// One sub-block under the Coordination layer in the Universal Detail.
/// A descriptor only opts in to the blocks that make sense for its
/// type; other blocks collapse (empty cluster = invisible).
public enum CoordinationBlockKind: String, Sendable, Hashable, CaseIterable {
    case money
    case schedule
    case access
    case responsibility
    case rules
    case usage

    /// Stable render order in the detail surface.
    public static let renderOrder: [CoordinationBlockKind] = [
        .money, .schedule, .access, .responsibility, .rules, .usage
    ]

    public var label: LocalizedStringResource {
        switch self {
        case .money:          return L10n.ResourceDetail.coordinationMoney
        case .schedule:       return L10n.ResourceDetail.coordinationSchedule
        case .access:         return L10n.ResourceDetail.coordinationAccess
        case .responsibility: return L10n.ResourceDetail.coordinationResponsibility
        case .rules:          return L10n.ResourceDetail.coordinationRules
        case .usage:          return L10n.ResourceDetail.coordinationUsage
        }
    }

    public var systemImageName: String {
        switch self {
        case .money:          return "creditcard"
        case .schedule:       return "calendar"
        case .access:         return "key"
        case .responsibility: return "person.badge.shield.checkmark"
        case .rules:          return "list.bullet.rectangle"
        case .usage:          return "chart.line.uptrend.xyaxis"
        }
    }
}

public struct MetadataField: Sendable, Identifiable {
    public var id: String { key }
    public let key: String
    public let label: LocalizedStringResource
    public let kind: Kind

    public enum Kind: String, Sendable, Hashable {
        case string
        case multilineString
        case integer
        case decimal
        case date
        case boolean
        case url
    }

    public init(key: String, label: LocalizedStringResource, kind: Kind) {
        self.key = key
        self.label = label
        self.kind = kind
    }
}

public enum ResourceTypeRegistry {
    /// O(1) lookup; every case has a descriptor.
    public static func descriptor(for type: GroupResourceType) -> ResourceTypeDescriptor {
        switch type {
        case .event:                return Descriptors.event
        case .fund:                 return Descriptors.fund
        case .slot:                 return Descriptors.slot
        case .space:                return Descriptors.space
        case .asset:                return Descriptors.asset
        case .right:                return Descriptors.right
        case .money:                return Descriptors.money
        case .time:                 return Descriptors.time
        case .points:               return Descriptors.points
        case .document:             return Descriptors.document
        case .data:                 return Descriptors.data
        case .access:               return Descriptors.access
        case .other:                return Descriptors.other
        case .vehicle:              return Descriptors.vehicle
        case .tool:                 return Descriptors.tool
        case .inventory:            return Descriptors.inventory
        case .realEstate:           return Descriptors.realEstate
        case .intellectualProperty: return Descriptors.intellectualProperty
        }
    }

    /// Canonical order used by pickers + grouped lists. Subtype-backed
    /// types lead so users find the "first-class" ones quickly; the
    /// generic + ledger-ish types tail.
    public static let displayOrder: [GroupResourceType] = [
        .fund, .space, .asset, .right, .slot, .event,
        .vehicle, .tool, .inventory, .realEstate,
        .intellectualProperty, .document, .data, .access,
        .money, .time, .points, .other
    ]
}

private enum Descriptors {
    static let event = ResourceTypeDescriptor(
        type: .event,
        label: L10n.Resources.eventLabel,
        subtitle: L10n.Resources.eventSubtitle,
        icon: "calendar",
        subtypeTable: "group_resource_events",
        coordinationBlocks: [.schedule, .responsibility, .money, .rules, .usage],
        supportsBooking: true,
        supportsAssignment: true,
        lifecycleEvents: [
            "resource.assigned", "resource.returned",
            "resource.used", "resource.value_updated"
        ]
    )

    static let fund = ResourceTypeDescriptor(
        type: .fund,
        label: L10n.Resources.fundLabel,
        subtitle: L10n.Resources.fundSubtitle,
        icon: "banknote",
        subtypeTable: "group_resource_funds",
        coordinationBlocks: [.money, .rules],
        supportsLocking: true,
        lifecycleEvents: ["resource.value_updated"],
        metadataSchema: [
            MetadataField(key: "currency", label: L10n.Resources.metaCurrency, kind: .string)
        ]
    )

    static let slot = ResourceTypeDescriptor(
        type: .slot,
        label: L10n.Resources.slotLabel,
        subtitle: L10n.Resources.slotSubtitle,
        icon: "clock.badge",
        subtypeTable: "group_resource_slots",
        coordinationBlocks: [.schedule, .responsibility, .rules],
        supportsAssignment: true,
        lifecycleEvents: ["resource.assigned", "resource.returned"]
    )

    static let space = ResourceTypeDescriptor(
        type: .space,
        label: L10n.Resources.spaceLabel,
        subtitle: L10n.Resources.spaceSubtitle,
        icon: "house",
        subtypeTable: "group_resource_spaces",
        coordinationBlocks: [.schedule, .access, .rules, .usage],
        supportsBooking: true,
        lifecycleEvents: ["resource.used", "resource.damaged", "resource.repaired"],
        metadataSchema: [
            MetadataField(key: "address",  label: L10n.Resources.metaAddress,  kind: .string),
            MetadataField(key: "capacity", label: L10n.Resources.metaCapacity, kind: .integer),
            MetadataField(key: "rules",    label: L10n.Resources.metaRules,    kind: .multilineString)
        ]
    )

    static let asset = ResourceTypeDescriptor(
        type: .asset,
        label: L10n.Resources.assetLabel,
        subtitle: L10n.Resources.assetSubtitle,
        icon: "shippingbox",
        subtypeTable: "group_resource_assets",
        coordinationBlocks: [.responsibility, .usage, .money, .rules],
        supportsValuation: true,
        supportsCustody: true,
        lifecycleEvents: [
            "resource.transferred", "resource.used", "resource.damaged",
            "resource.repaired", "resource.assigned", "resource.returned",
            "resource.value_updated", "resource.status_changed"
        ]
    )

    static let right = ResourceTypeDescriptor(
        type: .right,
        label: L10n.Resources.rightLabel,
        subtitle: L10n.Resources.rightSubtitle,
        icon: "key.horizontal",
        subtypeTable: "group_resource_rights",
        coordinationBlocks: [.access, .responsibility, .rules],
        supportsAssignment: true,
        lifecycleEvents: ["resource.assigned", "resource.transferred", "resource.returned"]
    )

    static let money = ResourceTypeDescriptor(
        type: .money,
        label: L10n.Resources.moneyLabel,
        subtitle: L10n.Resources.moneySubtitle,
        icon: "dollarsign.circle",
        subtypeTable: nil,
        coordinationBlocks: [.money],
        supportsValuation: true,
        lifecycleEvents: ["resource.value_updated"],
        metadataSchema: [
            MetadataField(key: "currency", label: L10n.Resources.metaCurrency, kind: .string),
            MetadataField(key: "amount",   label: L10n.Resources.metaAmount,   kind: .decimal)
        ]
    )

    static let time = ResourceTypeDescriptor(
        type: .time,
        label: L10n.Resources.timeLabel,
        subtitle: L10n.Resources.timeSubtitle,
        icon: "hourglass",
        subtypeTable: nil,
        coordinationBlocks: [.responsibility, .usage],
        lifecycleEvents: ["resource.used"],
        metadataSchema: [
            MetadataField(key: "hours",   label: L10n.Resources.metaHours,   kind: .decimal),
            MetadataField(key: "context", label: L10n.Resources.metaContext, kind: .string)
        ]
    )

    static let points = ResourceTypeDescriptor(
        type: .points,
        label: L10n.Resources.pointsLabel,
        subtitle: L10n.Resources.pointsSubtitle,
        icon: "star.circle",
        subtypeTable: nil,
        coordinationBlocks: [.money, .usage],
        supportsValuation: true,
        lifecycleEvents: ["resource.value_updated"],
        metadataSchema: [
            MetadataField(key: "scale",  label: L10n.Resources.metaScale,  kind: .string),
            MetadataField(key: "amount", label: L10n.Resources.metaAmount, kind: .decimal)
        ]
    )

    static let document = ResourceTypeDescriptor(
        type: .document,
        label: L10n.Resources.documentLabel,
        subtitle: L10n.Resources.documentSubtitle,
        icon: "doc.text",
        subtypeTable: nil,
        coordinationBlocks: [.access, .rules],
        metadataSchema: [
            MetadataField(key: "url",    label: L10n.Resources.metaUrl,    kind: .url),
            MetadataField(key: "format", label: L10n.Resources.metaFormat, kind: .string)
        ]
    )

    static let data = ResourceTypeDescriptor(
        type: .data,
        label: L10n.Resources.dataLabel,
        subtitle: L10n.Resources.dataSubtitle,
        icon: "externaldrive",
        subtypeTable: nil,
        coordinationBlocks: [.access, .rules],
        metadataSchema: [
            MetadataField(key: "source", label: L10n.Resources.metaSource, kind: .string),
            MetadataField(key: "url",    label: L10n.Resources.metaUrl,    kind: .url)
        ]
    )

    static let access = ResourceTypeDescriptor(
        type: .access,
        label: L10n.Resources.accessLabel,
        subtitle: L10n.Resources.accessSubtitle,
        icon: "lock.shield",
        subtypeTable: nil,
        coordinationBlocks: [.access, .responsibility, .rules],
        supportsAssignment: true,
        lifecycleEvents: ["resource.assigned", "resource.transferred"],
        metadataSchema: [
            MetadataField(key: "provider", label: L10n.Resources.metaProvider, kind: .string),
            MetadataField(key: "notes",    label: L10n.Resources.metaNotes,    kind: .multilineString)
        ]
    )

    static let other = ResourceTypeDescriptor(
        type: .other,
        label: L10n.Resources.otherLabel,
        subtitle: L10n.Resources.otherSubtitle,
        icon: "square.stack.3d.up",
        subtypeTable: nil,
        coordinationBlocks: [.usage],
        metadataSchema: [
            MetadataField(key: "notes", label: L10n.Resources.metaNotes, kind: .multilineString)
        ]
    )

    static let vehicle = ResourceTypeDescriptor(
        type: .vehicle,
        label: L10n.Resources.vehicleLabel,
        subtitle: L10n.Resources.vehicleSubtitle,
        icon: "car",
        subtypeTable: nil,
        coordinationBlocks: [.responsibility, .usage, .money],
        supportsValuation: true,
        supportsCustody: true,
        lifecycleEvents: [
            "resource.used", "resource.damaged", "resource.repaired",
            "resource.transferred", "resource.value_updated",
            "resource.status_changed"
        ],
        metadataSchema: [
            MetadataField(key: "make",    label: L10n.Resources.metaMake,    kind: .string),
            MetadataField(key: "model",   label: L10n.Resources.metaModel,   kind: .string),
            MetadataField(key: "plate",   label: L10n.Resources.metaPlate,   kind: .string),
            MetadataField(key: "mileage", label: L10n.Resources.metaMileage, kind: .decimal)
        ]
    )

    static let tool = ResourceTypeDescriptor(
        type: .tool,
        label: L10n.Resources.toolLabel,
        subtitle: L10n.Resources.toolSubtitle,
        icon: "hammer",
        subtypeTable: nil,
        coordinationBlocks: [.responsibility, .usage],
        lifecycleEvents: ["resource.used", "resource.damaged", "resource.repaired"],
        metadataSchema: [
            MetadataField(key: "condition", label: L10n.Resources.metaCondition, kind: .string)
        ]
    )

    static let inventory = ResourceTypeDescriptor(
        type: .inventory,
        label: L10n.Resources.inventoryLabel,
        subtitle: L10n.Resources.inventorySubtitle,
        icon: "tray.full",
        subtypeTable: nil,
        coordinationBlocks: [.usage, .money],
        supportsValuation: true,
        lifecycleEvents: ["resource.used", "resource.value_updated"],
        metadataSchema: [
            MetadataField(key: "quantity",  label: L10n.Resources.metaQuantity,  kind: .decimal),
            MetadataField(key: "threshold", label: L10n.Resources.metaThreshold, kind: .decimal),
            MetadataField(key: "unit",      label: L10n.Resources.metaUnit,      kind: .string)
        ]
    )

    static let realEstate = ResourceTypeDescriptor(
        type: .realEstate,
        label: L10n.Resources.realEstateLabel,
        subtitle: L10n.Resources.realEstateSubtitle,
        icon: "building.2",
        subtypeTable: nil,
        coordinationBlocks: [.responsibility, .money, .rules],
        supportsValuation: true,
        supportsCustody: true,
        lifecycleEvents: [
            "resource.value_updated", "resource.damaged",
            "resource.repaired", "resource.transferred"
        ],
        metadataSchema: [
            MetadataField(key: "address", label: L10n.Resources.metaAddress, kind: .multilineString)
        ]
    )

    static let intellectualProperty = ResourceTypeDescriptor(
        type: .intellectualProperty,
        label: L10n.Resources.intellectualPropertyLabel,
        subtitle: L10n.Resources.intellectualPropertySubtitle,
        icon: "lightbulb",
        subtypeTable: nil,
        coordinationBlocks: [.responsibility, .money, .rules],
        supportsValuation: true,
        lifecycleEvents: ["resource.value_updated", "resource.transferred"],
        metadataSchema: [
            MetadataField(key: "ip_kind",             label: L10n.Resources.metaIpKind,       kind: .string),
            MetadataField(key: "registration_number", label: L10n.Resources.metaRegistration, kind: .string),
            MetadataField(key: "registry",            label: L10n.Resources.metaRegistry,     kind: .string),
            MetadataField(key: "expires_at",          label: L10n.Resources.metaExpiresAt,    kind: .date)
        ]
    )
}
