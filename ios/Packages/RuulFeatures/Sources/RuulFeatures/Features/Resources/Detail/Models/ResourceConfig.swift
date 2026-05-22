//
//  ResourceConfig.swift
//  ResourceKit
//
//  Public models that describe a resource's detail screen. The universal
//  `ResourceDetailContent` shell renders any `ResourceConfig`; each
//  resource family (Event, Fund, Vote, Fine, Space, …) builds one via
//  the factory extensions in `Factories/ResourceConfig+*.swift`.
//
//  This file is **public API**. Changing the shape of any type here
//  ripples through every caller (factories, hosts, sheets, blocks).
//

import SwiftUI
import MapKit
import CoreLocation
import RuulCore
import RuulUI

// MARK: ════════════════════════════════════════════════════════════════════
// MARK: 1. CONFIGURACIÓN DEL RECURSO
// MARK: ════════════════════════════════════════════════════════════════════

/// Configuración completa de la vista de detalle de un recurso.
/// Cada tipo de recurso (Evento, Fondo, etc.) construye un `ResourceConfig`
/// declarando qué llena en cada slot.
public struct ResourceConfig {
    public let identity: IdentityData
    public let accent: Color
    public let hero: HeroData?
    public let actions: [ResourceAction]
    public let sections: [ResourceSection]
    public let activity: ActivitySource?
    public let toolbarMenu: [ToolbarMenuItem]
    /// Group the resource belongs to. When non-nil the detail renders a
    /// `GroupContextSlot` right under the identity ribbon so the user
    /// always sees which group originated the resource (Founder doctrine
    /// 2026-05-20 §3 — "no orphan resources").
    public let groupContext: GroupContextData?

    /// SharedMoney Phase 4: when non-nil, the detail renders a
    /// `ResourceMoneySlot` after sections showing what the group has
    /// spent / contributed attributed to this resource via
    /// `ledger_entries.source_resource_id`. Polymorphic across resource
    /// types (event/asset/space/etc.) — the slot only needs the
    /// `(groupId, resourceId, currency, members)` tuple. Resources
    /// without a money story (e.g. internal bookkeeping rows) leave it
    /// nil and the slot is omitted.
    public let moneyContext: MoneyContext?

    public init(
        identity: IdentityData,
        accent: Color,
        hero: HeroData? = nil,
        actions: [ResourceAction] = [],
        sections: [ResourceSection] = [],
        activity: ActivitySource? = nil,
        toolbarMenu: [ToolbarMenuItem] = [],
        groupContext: GroupContextData? = nil,
        moneyContext: MoneyContext? = nil
    ) {
        self.identity = identity
        self.accent = accent
        self.hero = hero
        self.actions = actions
        self.sections = sections
        self.activity = activity
        self.toolbarMenu = toolbarMenu
        self.groupContext = groupContext
        self.moneyContext = moneyContext
    }
}

// MARK: - Money context

/// Carries the (group + resource + currency + members) tuple the
/// universal Money Block needs to load `resource_money_view` and present
/// the group-scoped sheets pre-filled with `sourceResource`. See doctrine
/// `doctrine_in_kind_contributions.md` — capital contributions land here
/// too (not just reimbursable expenses).
public struct MoneyContext {
    public let groupId: UUID
    public let resourceId: UUID
    public let resourceName: String
    public let currency: String
    public let members: [MemberWithProfile]
    /// Called after a successful contribute / record-expense so the
    /// host can refresh its own state (activity feed, related counters).
    public let onDidChange: () -> Void

    public init(
        groupId: UUID,
        resourceId: UUID,
        resourceName: String,
        currency: String,
        members: [MemberWithProfile],
        onDidChange: @escaping () -> Void = {}
    ) {
        self.groupId = groupId
        self.resourceId = resourceId
        self.resourceName = resourceName
        self.currency = currency
        self.members = members
        self.onDidChange = onDidChange
    }
}

// MARK: - Group context

/// Carried alongside `ResourceConfig` to render the persistent "En
/// {Group}" / "Propuesto por {x}" card under the identity ribbon. The
/// avatar uses a simple gradient pair to stay light — no per-group
/// branded color is required.
public struct GroupContextData {
    public let groupName: String
    public let groupInitials: String
    public let proposedBy: String?
    public let proposedAt: Date?
    public let onTapGroup: () -> Void

    public init(
        groupName: String,
        groupInitials: String,
        proposedBy: String? = nil,
        proposedAt: Date? = nil,
        onTapGroup: @escaping () -> Void = {}
    ) {
        self.groupName = groupName
        self.groupInitials = groupInitials
        self.proposedBy = proposedBy
        self.proposedAt = proposedAt
        self.onTapGroup = onTapGroup
    }
}

// MARK: - Identity

public struct IdentityData {
    public let iconSystemName: String       // SF Symbol: "calendar", "banknote", "key.fill"
    public let name: String
    public let typeLabel: String            // "Evento", "Fondo", "Espacio"
    public let metadata: [String]           // ["Hoy", "3 participantes"]
    public let badge: ResourceBadge?

    public init(
        iconSystemName: String,
        name: String,
        typeLabel: String,
        metadata: [String] = [],
        badge: ResourceBadge? = nil
    ) {
        self.iconSystemName = iconSystemName
        self.name = name
        self.typeLabel = typeLabel
        self.metadata = metadata
        self.badge = badge
    }
}

public struct ResourceBadge {
    public let text: String
    public let color: Color

    public init(text: String, color: Color) {
        self.text = text
        self.color = color
    }
}

// MARK: - Hero

public struct HeroData {
    public let value: String        // "$0.00", "2:03 p.m.", "Disponible"
    public let label: String        // "Saldo en MXN", "21 may · 180 min"
    public let size: HeroSize
    public let subRow: [HeroPair]?  // [HeroPair("Aportado", "$0"), …]

    public init(
        value: String,
        label: String,
        size: HeroSize = .title,
        subRow: [HeroPair]? = nil
    ) {
        self.value = value
        self.label = label
        self.size = size
        self.subRow = subRow
    }
}

/// Named pair for the hero sub-row. Replaces the older `(String, String)`
/// tuple shape so `ForEach` can use the label as a stable identity
/// instead of array offset (which breaks animations when pairs reorder).
public struct HeroPair: Identifiable, Hashable, Sendable {
    public var id: String { label }
    public let label: String
    public let value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

public enum HeroSize {
    case display    // 42pt — saldos, métricas numéricas clave
    case title      // 30pt — fechas, estados textuales
}

// MARK: - Actions

public struct ResourceAction: Identifiable {
    public let id = UUID()
    public let label: String
    public let icon: String?                // SF Symbol opcional
    public let tint: Color?                 // nil → acción secundaria (gris)
    public let role: ButtonRole?            // .destructive si aplica
    public let handler: () -> Void

    public init(
        label: String,
        icon: String? = nil,
        tint: Color? = nil,
        role: ButtonRole? = nil,
        handler: @escaping () -> Void
    ) {
        self.label = label
        self.icon = icon
        self.tint = tint
        self.role = role
        self.handler = handler
    }
}

// MARK: - Sections

public enum ResourceSection: Identifiable {
    case rows(title: String, items: [RowItem])
    case map(title: String, location: MapLocation)
    case avatars(title: String, people: [Person], emptyText: String?, onTapMore: (() -> Void)?)
    case empty(title: String, icon: String, message: String, description: String)
    case custom(id: String, title: String?, content: AnyView)

    public var id: String {
        switch self {
        case .rows(let t, _):     return "rows-\(t)"
        case .map(let t, _):      return "map-\(t)"
        case .avatars(let t, _, _, _): return "avatars-\(t)"
        case .empty(let t, _, _, _):   return "empty-\(t)"
        case .custom(let id, _, _):    return "custom-\(id)"
        }
    }
}

public struct RowItem: Identifiable {
    public let id = UUID()
    public let icon: String?                // SF Symbol opcional
    public let label: String
    public let value: RowValue
    public let onTap: (() -> Void)?

    public init(
        icon: String? = nil,
        label: String,
        value: RowValue,
        onTap: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.label = label
        self.value = value
        self.onTap = onTap
    }
}

public enum RowValue {
    case text(String)
    case link(String)                       // estilo navegación (azul + chevron)
    case toggle(Binding<Bool>)
}

public struct Person: Identifiable {
    public let id: String
    public let name: String
    public let initials: String
    public let color: Color
    public let imageURL: URL?

    public init(id: String, name: String, initials: String, color: Color, imageURL: URL? = nil) {
        self.id = id
        self.name = name
        self.initials = initials
        self.color = color
        self.imageURL = imageURL
    }
}

public struct MapLocation: Equatable {
    public let coordinate: CLLocationCoordinate2D
    public let address: String
    public let title: String?

    public init(coordinate: CLLocationCoordinate2D, address: String, title: String? = nil) {
        self.coordinate = coordinate
        self.address = address
        self.title = title
    }

    public static func == (lhs: MapLocation, rhs: MapLocation) -> Bool {
        lhs.coordinate.latitude == rhs.coordinate.latitude &&
        lhs.coordinate.longitude == rhs.coordinate.longitude &&
        lhs.address == rhs.address
    }
}

// MARK: - Activity

/// La actividad puede ser estática (array fijo) o paginada (loader async).
public enum ActivitySource {
    case `static`([ActivityItem])
    case paginated(ActivityLoader)
}

public struct ActivityItem: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let timestamp: Date
    public let icon: String?
    public let kind: ActivityKind
    /// Pre-formatted relative time string. When non-nil the view uses it
    /// directly instead of computing from `timestamp` (lets callers feed
    /// already-localized strings like "hace 2h" from `ActivityEntry`).
    public let prebakedRelativeTime: String?

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        timestamp: Date,
        icon: String? = nil,
        kind: ActivityKind = .neutral,
        prebakedRelativeTime: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.timestamp = timestamp
        self.icon = icon
        self.kind = kind
        self.prebakedRelativeTime = prebakedRelativeTime
    }
}

public enum ActivityKind: Equatable {
    case neutral, positive, negative, warning

    var color: Color {
        switch self {
        case .neutral:  return Color.ruulTextTertiary
        case .positive: return .ruulSemanticSuccess
        case .negative: return .ruulSemanticError
        case .warning:  return .ruulSemanticWarning
        }
    }
}

public struct ActivityPage: Equatable {
    public let items: [ActivityItem]
    public let nextCursor: String?

    public init(items: [ActivityItem], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public protocol ActivityLoader: Sendable {
    func load(cursor: String?) async throws -> ActivityPage
}

// MARK: - Toolbar Menu

public struct ToolbarMenuItem: Identifiable {
    public let id = UUID()
    public let label: String
    public let icon: String
    public let role: ButtonRole?
    public let handler: () -> Void

    public init(label: String, icon: String, role: ButtonRole? = nil, handler: @escaping () -> Void) {
        self.label = label
        self.icon = icon
        self.role = role
        self.handler = handler
    }
}
