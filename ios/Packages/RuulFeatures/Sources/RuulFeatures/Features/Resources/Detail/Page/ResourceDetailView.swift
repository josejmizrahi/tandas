//
//  ResourceDetailView.swift
//  ResourceKit
//
//  Sistema universal para mostrar el detalle de cualquier recurso
//  (Evento, Fondo, Espacio, Documento, Votación, etc.) con UI consistente
//  siguiendo las prácticas de Apple iOS 26 (Liquid Glass, jerarquía clara,
//  empty states correctos, paginación nativa).
//
//  ARQUITECTURA
//  ────────────
//  Tres niveles:
//
//  1. Shell universal (toolbar, scroll, fondo, padding) → NUNCA se reimplementa
//  2. Slots estándar (Identity, Hero, Actions, Sections, Activity) → 90% de casos
//  3. Escape hatch .custom(AnyView) → 10% de casos especiales
//
//  Cada tipo de recurso declara UNA función estática que devuelve un
//  `ResourceConfig`. El componente universal renderiza esa config.
//
//  USO BÁSICO
//  ──────────
//  ResourceDetailView(config: .event(myEvent))
//  ResourceDetailView(config: .fund(myFund))
//  ResourceDetailView(config: .space(mySpace))
//
//  PARA AGREGAR UN RECURSO NUEVO
//  ─────────────────────────────
//  1. Definí el modelo (struct MyResource).
//  2. Agregá `static func myResource(_ r: MyResource) -> ResourceConfig`
//     en `extension ResourceConfig`.
//  3. Si necesitás un slot que no existe, usá .custom(AnyView(...)).
//  4. Si el .custom se repite en 3+ recursos, promovelo a slot estándar
//     agregando un caso al enum ResourceSection.
//
//  NOTA — `EventInput`/`FundInput`/`SpaceInput` son los modelos de ejemplo
//  del archivo original (era `Event`/`Fund`/`Space`). Renombrados para
//  no chocar con `RuulCore.Event` / `RuulCore.Fund`. Reemplazar con los
//  del dominio real vía un adapter cuando se wireé.

import SwiftUI
import MapKit
import CoreLocation
import UIKit
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

    public init(
        identity: IdentityData,
        accent: Color,
        hero: HeroData? = nil,
        actions: [ResourceAction] = [],
        sections: [ResourceSection] = [],
        activity: ActivitySource? = nil,
        toolbarMenu: [ToolbarMenuItem] = [],
        groupContext: GroupContextData? = nil
    ) {
        self.identity = identity
        self.accent = accent
        self.hero = hero
        self.actions = actions
        self.sections = sections
        self.activity = activity
        self.toolbarMenu = toolbarMenu
        self.groupContext = groupContext
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
    public let value: String                // "$0.00", "2:03 p.m.", "Disponible"
    public let label: String                // "Saldo en MXN", "21 may · 180 min"
    public let size: HeroSize
    public let subRow: [(String, String)]?  // [("Aportado", "$0"), ...]

    public init(
        value: String,
        label: String,
        size: HeroSize = .title,
        subRow: [(String, String)]? = nil
    ) {
        self.value = value
        self.label = label
        self.size = size
        self.subRow = subRow
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

// MARK: ════════════════════════════════════════════════════════════════════
// MARK: 2. SHELL UNIVERSAL
// MARK: ════════════════════════════════════════════════════════════════════

public struct ResourceDetailView: View {
    let config: ResourceConfig

    @Environment(\.dismiss) private var dismiss

    public init(config: ResourceConfig) {
        self.config = config
    }

    public var body: some View {
        NavigationStack {
            ResourceDetailContent(config: config)
                .navigationTitle(config.identity.typeLabel)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cerrar") { dismiss() }
                    }
                    if !config.toolbarMenu.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                ForEach(config.toolbarMenu) { item in
                                    Button(role: item.role, action: item.handler) {
                                        Label(item.label, systemImage: item.icon)
                                    }
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                            }
                        }
                    }
                }
        }
    }
}

/// Embeddable body — same content as `ResourceDetailView` but without the
/// NavigationStack/toolbar wrapper. Use when the host already owns the
/// navigation chrome (e.g. `EventDetailHost` wraps in its own `.ruulSheetToolbar`).
public struct ResourceDetailContent: View {
    let config: ResourceConfig

    public init(config: ResourceConfig) {
        self.config = config
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: RuulSpacing.s0) {
                IdentitySlot(data: config.identity, accent: config.accent)
                    .padding(.horizontal, RuulSpacing.s5)
                    .padding(.top, RuulSpacing.s2)

                if let ctx = config.groupContext {
                    GroupContextSlot(data: ctx)
                        .padding(.horizontal, RuulSpacing.s5)
                        .padding(.top, RuulSpacing.s3)
                }

                if let hero = config.hero {
                    HeroSlot(data: hero)
                        .padding(.horizontal, RuulSpacing.s5)
                        .padding(.top, RuulSpacing.s3)
                }

                if !config.actions.isEmpty {
                    ActionsSlot(actions: config.actions, accent: config.accent)
                        .padding(.horizontal, RuulSpacing.s5)
                        .padding(.top, RuulSpacing.s4)
                }

                ForEach(config.sections) { section in
                    SectionSlot(section: section, accent: config.accent)
                        .padding(.horizontal, RuulSpacing.s5)
                        .padding(.top, RuulSpacing.s5)
                }

                if let activity = config.activity {
                    ActivitySlot(source: activity, accent: config.accent)
                        .padding(.horizontal, RuulSpacing.s5)
                        .padding(.top, RuulSpacing.s5)
                }

                Color.clear.frame(height: 32)
            }
        }
        .background(Color.ruulBackgroundRecessed)
        .scrollDismissesKeyboard(.interactively)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .tint(config.accent)
    }
}

// MARK: ════════════════════════════════════════════════════════════════════
// MARK: 3. SLOTS ESTÁNDAR
// MARK: ════════════════════════════════════════════════════════════════════

// MARK: Identity

struct IdentitySlot: View {
    let data: IdentityData
    let accent: Color

    var body: some View {
        HStack(spacing: RuulSpacing.s3) {
            RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                .fill(accent.opacity(0.15))
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: data.iconSystemName)
                        .font(.system(size: 26, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(accent)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(data.name)
                    .font(.title2.weight(.bold))
                    .lineLimit(2)

                HStack(spacing: RuulSpacing.micro) {
                    Text(subtitleSegments.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .lineLimit(1)

                    if let badge = data.badge {
                        BadgeView(badge: badge)
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    /// Joins `[typeLabel] + metadata` while filtering out any metadata
    /// entry that already equals `typeLabel` (case-insensitive). Prevents
    /// the "Fondo · Fondo" duplication seen when block builders push the
    /// resource family label into `subtitleSegments`.
    private var subtitleSegments: [String] {
        let label = data.typeLabel.trimmingCharacters(in: .whitespaces)
        let extras = data.metadata.filter {
            !$0.trimmingCharacters(in: .whitespaces)
                .caseInsensitiveEquivalent(label)
        }
        return label.isEmpty ? extras : [label] + extras
    }
}

private extension String {
    func caseInsensitiveEquivalent(_ other: String) -> Bool {
        compare(other, options: .caseInsensitive) == .orderedSame
    }
}

// MARK: GroupContextSlot

/// Subtle Liquid Glass card showing the parent group + provenance.
/// Drives the "no orphan resource" doctrine: tapping lifts the viewer
/// out of the resource and into the group surface that owns it.
///
/// Visual treatment is **fase 1 doctrine** — `.ruulGlass(.thin)` for the
/// blur+depth surface (auto fallback to `ruulSurface` under reduce-
/// transparency) and design system color tokens for every fill / text
/// (no hardcoded `.indigo` / `.purple` / `.primary` / `.tertiary`).
struct GroupContextSlot: View {
    let data: GroupContextData

    @State private var tapTick: Int = 0

    var body: some View {
        Button(action: {
            tapTick &+= 1
            data.onTapGroup()
        }) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.ruulAccentMuted)
                    .frame(width: 26, height: 26)
                    .overlay(
                        Text(data.groupInitials)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.ruulAccent)
                    )

                contextText
                    .font(.footnote)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            .padding(.horizontal, RuulSpacing.s3)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .ruulGlass(
            RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous),
            material: .thin,
            interactive: true
        )
        .sensoryFeedback(.selection, trigger: tapTick)
    }

    private var contextText: Text {
        var t = Text("En ").foregroundColor(Color.ruulTextSecondary)
            + Text(data.groupName).fontWeight(.semibold).foregroundColor(Color.ruulTextPrimary)
        if let by = data.proposedBy {
            t = t
                + Text(" · Propuesto por ").foregroundColor(Color.ruulTextSecondary)
                + Text(by).fontWeight(.semibold).foregroundColor(Color.ruulTextPrimary)
        }
        if let at = data.proposedAt {
            t = t
                + Text(" ").foregroundColor(Color.ruulTextSecondary)
                + Text(at, style: .relative).foregroundColor(Color.ruulTextTertiary)
        }
        return t
    }
}

struct BadgeView: View {
    let badge: ResourceBadge

    var body: some View {
        Text(badge.text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(badge.color)
            .padding(.horizontal, RuulSpacing.s2)
            .padding(.vertical, RuulSpacing.s0_5)
            .background(badge.color.opacity(0.15), in: Capsule())
    }
}

// MARK: Hero

struct HeroSlot: View {
    let data: HeroData

    var body: some View {
        VStack(spacing: RuulSpacing.micro) {
            Text(data.value)
                .font(heroFont)
                .fontDesign(.rounded)
                .fontWeight(.bold)
                .contentTransition(.numericText())
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.85)

            Text(data.label)
                .font(.footnote)
                .foregroundStyle(Color.ruulTextSecondary)
                .multilineTextAlignment(.center)

            if let subRow = data.subRow, !subRow.isEmpty {
                HStack(spacing: RuulSpacing.s5) {
                    ForEach(Array(subRow.enumerated()), id: \.offset) { _, pair in
                        HStack(spacing: RuulSpacing.s1) {
                            Text(pair.0)
                                .foregroundStyle(Color.ruulTextSecondary)
                            Text(pair.1)
                                .fontWeight(.semibold)
                        }
                        .font(.caption)
                    }
                }
                .padding(.top, RuulSpacing.micro)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, RuulSpacing.s2)
    }

    private var heroFont: Font {
        switch data.size {
        case .display: return .system(size: 42)
        case .title:   return .system(size: 30)
        }
    }
}

// MARK: Actions

struct ActionsSlot: View {
    let actions: [ResourceAction]
    let accent: Color

    var body: some View {
        HStack(spacing: RuulSpacing.s2) {
            ForEach(actions) { action in
                Button(role: action.role, action: action.handler) {
                    HStack(spacing: RuulSpacing.micro) {
                        if let icon = action.icon {
                            Image(systemName: icon)
                                .font(.footnote.weight(.semibold))
                        }
                        Text(action.label)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 38)
                }
                .buttonStyle(.glassProminent)
                .tint(action.tint ?? Color.ruulFillGlassStrong)
            }
        }
    }
}

// MARK: Section dispatcher

struct SectionSlot: View {
    let section: ResourceSection
    let accent: Color

    var body: some View {
        switch section {
        case .rows(let title, let items):
            RowsSection(title: title, items: items, accent: accent)
        case .map(let title, let location):
            MapSection(title: title, location: location, accent: accent)
        case .avatars(let title, let people, let emptyText, let onTapMore):
            AvatarsSection(title: title, people: people, emptyText: emptyText, accent: accent, onTapMore: onTapMore)
        case .empty(let title, let icon, let message, let description):
            EmptySection(title: title, icon: icon, message: message, description: description)
        case .custom(_, let title, let content):
            CustomSection(title: title, content: content)
        }
    }
}

// MARK: Rows

struct RowsSection: View {
    let title: String
    let items: [RowItem]
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            SectionHeader(title: title)

            VStack(spacing: RuulSpacing.s0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    RowView(item: item, accent: accent)
                    if index < items.count - 1 {
                        Divider().padding(.leading, item.icon != nil ? 46 : 14)
                    }
                }
            }
            .background(Color.ruulSurface)
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
        }
    }
}

struct RowView: View {
    let item: RowItem
    let accent: Color

    var body: some View {
        Button(action: { item.onTap?() }) {
            HStack(spacing: 10) {
                if let icon = item.icon {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(accent)
                        .frame(width: 22)
                }

                Text(item.label)
                    .font(.subheadline)
                    .foregroundStyle(Color.ruulTextPrimary)

                Spacer(minLength: 8)

                switch item.value {
                case .text(let value):
                    Text(value)
                        .font(.subheadline)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                case .link(let value):
                    HStack(spacing: RuulSpacing.s1) {
                        Text(value)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(accent)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.ruulTextTertiary)
                    }
                case .toggle(let binding):
                    Toggle(item.label, isOn: binding)
                        .labelsHidden()
                        .tint(accent)
                        .accessibilityLabel(item.label)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, RuulSpacing.s3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.onTap == nil && !isInteractive)
    }

    private var isInteractive: Bool {
        if case .toggle = item.value { return true }
        if case .link = item.value { return true }
        return false
    }
}

// MARK: Map

struct MapSection: View {
    let title: String
    let location: MapLocation
    let accent: Color

    @State private var cameraPosition: MapCameraPosition
    @State private var showingOptions = false
    @Environment(\.openURL) private var openURL

    init(title: String, location: MapLocation, accent: Color) {
        self.title = title
        self.location = location
        self.accent = accent
        self._cameraPosition = State(initialValue: .region(
            MKCoordinateRegion(
                center: location.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
            )
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            SectionHeader(title: title)

            VStack(alignment: .leading, spacing: RuulSpacing.s0) {
                Map(position: $cameraPosition, interactionModes: []) {
                    Marker(location.title ?? "Ubicación", coordinate: location.coordinate)
                        .tint(accent)
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll, showsTraffic: false))
                .frame(height: 140)
                .contentShape(Rectangle())
                .onTapGesture { openInAppleMaps() }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(location.title ?? "Ubicación")
                .accessibilityValue(location.address)
                .accessibilityHint("Toca para abrir en Mapas")
                .accessibilityAddTraits(.isButton)

                VStack(alignment: .leading, spacing: 10) {
                    if let t = location.title {
                        Text(t).font(.subheadline.weight(.semibold))
                    }
                    Text(location.address)
                        .font(.subheadline)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .lineLimit(3)

                    HStack(spacing: RuulSpacing.s2) {
                        Button(action: openInAppleMaps) {
                            Label("Abrir en Mapas", systemImage: "arrow.up.right.square")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.glass)
                        .tint(accent)

                        Button { showingOptions = true } label: {
                            Image(systemName: "ellipsis")
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.glass)
                        .tint(Color.ruulFillGlassStrong)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, RuulSpacing.s3)
            }
            .background(Color.ruulSurface)
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
            .confirmationDialog("Direcciones", isPresented: $showingOptions, titleVisibility: .hidden) {
                Button("Apple Maps")  { openInAppleMaps() }
                Button("Google Maps") { openInGoogleMaps() }
                Button("Waze")        { openInWaze() }
                Button("Copiar dirección") { UIPasteboard.general.string = location.address }
                Button("Cancelar", role: .cancel) {}
            }
        }
    }

    private func openInAppleMaps() {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
        item.name = location.title ?? location.address
        item.openInMaps()
    }

    private func openInGoogleMaps() {
        let coord = location.coordinate
        let app = URL(string: "comgooglemaps://?q=\(coord.latitude),\(coord.longitude)")
        let web = URL(string: "https://maps.google.com/?q=\(coord.latitude),\(coord.longitude)")
        if let app, UIApplication.shared.canOpenURL(app) { openURL(app) }
        else if let web { openURL(web) }
    }

    private func openInWaze() {
        let coord = location.coordinate
        let app = URL(string: "waze://?ll=\(coord.latitude),\(coord.longitude)&navigate=yes")
        let web = URL(string: "https://www.waze.com/ul?ll=\(coord.latitude),\(coord.longitude)&navigate=yes")
        if let app, UIApplication.shared.canOpenURL(app) { openURL(app) }
        else if let web { openURL(web) }
    }
}

// MARK: Avatars

struct AvatarsSection: View {
    let title: String
    let people: [Person]
    let emptyText: String?
    let accent: Color
    let onTapMore: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            SectionHeader(title: title)

            Button(action: { onTapMore?() }) {
                HStack(spacing: RuulSpacing.s3) {
                    if people.isEmpty {
                        HStack(spacing: -10) {
                            ForEach(0..<3, id: \.self) { _ in
                                Circle()
                                    .fill(Color.ruulSurfaceGlassThin)
                                    .frame(width: 30, height: 30)
                                    .overlay(
                                        Image(systemName: "plus")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(Color.ruulTextTertiary)
                                    )
                                    .overlay(Circle().stroke(Color.ruulSurface, lineWidth: 2))
                            }
                        }
                        Text(emptyText ?? "Aún nadie")
                            .font(.subheadline)
                            .foregroundStyle(Color.ruulTextSecondary)
                    } else {
                        HStack(spacing: -10) {
                            ForEach(people.prefix(3)) { person in
                                AvatarView(person: person)
                            }
                            if people.count > 3 {
                                Circle()
                                    .fill(Color.ruulSurfaceGlassThin)
                                    .frame(width: 30, height: 30)
                                    .overlay(Text("+\(people.count - 3)").font(.caption2.weight(.bold)).foregroundStyle(Color.ruulTextSecondary))
                                    .overlay(Circle().stroke(Color.ruulSurface, lineWidth: 2))
                            }
                        }
                        Text("\(people.count) \(people.count == 1 ? "persona" : "personas")")
                            .font(.subheadline)
                            .foregroundStyle(Color.ruulTextSecondary)
                    }

                    Spacer(minLength: 8)

                    if onTapMore != nil {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.ruulTextTertiary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, RuulSpacing.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onTapMore == nil)
            .background(Color.ruulSurface)
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
        }
    }
}

struct AvatarView: View {
    let person: Person

    var body: some View {
        Group {
            if let url = person.imageURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.ruulSurface, lineWidth: 2))
    }

    private var fallback: some View {
        person.color
            .overlay(
                Text(person.initials)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
            )
    }
}

// MARK: Empty (within section)

struct EmptySection: View {
    let title: String
    let icon: String
    let message: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            SectionHeader(title: title)

            ContentUnavailableView(
                message,
                systemImage: icon,
                description: Text(description)
            )
            .frame(maxWidth: .infinity)
            .background(Color.ruulSurface)
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
        }
    }
}

// MARK: Custom (escape hatch)

struct CustomSection: View {
    let title: String?
    let content: AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            if let title { SectionHeader(title: title) }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.ruulSurface)
                .clipShape(RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
        }
    }
}

// MARK: Section header (reusable)

struct SectionHeader: View {
    let title: String
    var body: some View {
        // V2 cherry-pick: iOS-26-native grouped-list header — title case,
        // subheadline, secondary. Replaces the older all-caps + tracking
        // variant which read as a print convention rather than as Apple's
        // native section style.
        Text(title)
            .font(.subheadline)
            .foregroundStyle(Color.ruulTextSecondary)
            .padding(.horizontal, RuulSpacing.s1)
    }
}

// MARK: ════════════════════════════════════════════════════════════════════
// MARK: 4. ACTIVITY SLOT (con paginación)
// MARK: ════════════════════════════════════════════════════════════════════

struct ActivitySlot: View {
    let source: ActivitySource
    let accent: Color

    var body: some View {
        switch source {
        case .static(let items):
            ActivityStaticView(items: items, accent: accent)
        case .paginated(let loader):
            ActivityPaginatedView(loader: loader, accent: accent)
        }
    }
}

struct ActivityStaticView: View {
    let items: [ActivityItem]
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            SectionHeader(title: "Actividad")
            if items.isEmpty {
                ActivityEmptyView()
            } else {
                ActivityGroupedTimeline(items: items, accent: accent)
            }
        }
    }
}

struct ActivityPaginatedView: View {
    let loader: ActivityLoader
    let accent: Color

    @State private var viewModel: ActivityViewModel

    init(loader: ActivityLoader, accent: Color) {
        self.loader = loader
        self.accent = accent
        self._viewModel = State(wrappedValue: ActivityViewModel(loader: loader))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            SectionHeader(title: "Actividad")

            switch viewModel.phase {
            case .idle, .loadingFirst:
                if viewModel.items.isEmpty {
                    ActivitySkeletonView()
                } else {
                    paginatedContent
                }
            case .error(let msg) where viewModel.items.isEmpty:
                ActivityErrorView(message: msg, accent: accent) { viewModel.loadFirst() }
            default:
                if viewModel.items.isEmpty {
                    ActivityEmptyView()
                } else {
                    paginatedContent
                }
            }
        }
        .onAppear { viewModel.loadInitialIfNeeded() }
    }

    private var paginatedContent: some View {
        VStack(spacing: 14) {
            ActivityGroupedTimeline(items: viewModel.items, accent: accent)

            if viewModel.hasMore {
                HStack(spacing: RuulSpacing.s2) {
                    if viewModel.phase == .loadingMore {
                        ProgressView().controlSize(.small)
                        Text("Cargando más…")
                            .font(.footnote).foregroundStyle(Color.ruulTextSecondary)
                    } else {
                        Color.clear.frame(height: 1)
                            .onAppear { viewModel.loadMore() }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, RuulSpacing.s3)
            }

            if case .error(let msg) = viewModel.phase, !viewModel.items.isEmpty {
                HStack(spacing: RuulSpacing.s2) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.ruulSemanticWarning)
                    Text(msg).font(.footnote).foregroundStyle(Color.ruulTextSecondary)
                    Button("Reintentar") { viewModel.loadMore() }
                        .font(.footnote.weight(.semibold))
                        .tint(accent)
                }
                .padding(.vertical, RuulSpacing.s2)
            }
        }
    }
}

@MainActor
@Observable
final class ActivityViewModel {
    private(set) var items: [ActivityItem] = []
    private(set) var phase: Phase = .idle
    private(set) var hasMore: Bool = true

    private var cursor: String?
    private let loader: ActivityLoader
    private var task: Task<Void, Never>?

    enum Phase: Equatable {
        case idle, loadingFirst, loadingMore, refreshing, loaded
        case error(String)
    }

    init(loader: ActivityLoader) { self.loader = loader }

    func loadInitialIfNeeded() {
        guard items.isEmpty, phase == .idle else { return }
        loadFirst()
    }

    func loadFirst() {
        task?.cancel()
        phase = .loadingFirst
        cursor = nil
        task = Task {
            do {
                let page = try await loader.load(cursor: nil)
                guard !Task.isCancelled else { return }
                items = page.items
                cursor = page.nextCursor
                hasMore = page.nextCursor != nil
                phase = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                phase = .error(error.localizedDescription)
            }
        }
    }

    func loadMore() {
        guard hasMore, phase != .loadingMore, phase != .loadingFirst, let cursor else { return }
        phase = .loadingMore
        task = Task {
            do {
                let page = try await loader.load(cursor: cursor)
                guard !Task.isCancelled else { return }
                let existing = Set(items.map(\.id))
                items.append(contentsOf: page.items.filter { !existing.contains($0.id) })
                self.cursor = page.nextCursor
                hasMore = page.nextCursor != nil
                phase = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                phase = .error(error.localizedDescription)
            }
        }
    }
}

struct ActivityGroupedTimeline: View {
    let items: [ActivityItem]
    let accent: Color

    var body: some View {
        VStack(spacing: 14) {
            ForEach(groups, id: \.label) { group in
                VStack(alignment: .leading, spacing: RuulSpacing.s0) {
                    Text(group.label)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.ruulTextSecondary)
                        .padding(.horizontal, RuulSpacing.s1)
                        .padding(.bottom, RuulSpacing.micro)

                    VStack(spacing: RuulSpacing.s0) {
                        ForEach(Array(group.items.enumerated()), id: \.element.id) { i, item in
                            ActivityRowView(item: item, accent: accent)
                            if i < group.items.count - 1 {
                                Divider().padding(.leading, 36)
                            }
                        }
                    }
                    .background(Color.ruulSurface)
                    .clipShape(RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
                }
            }
        }
    }

    private struct ActivityBucket { let label: String; let items: [ActivityItem] }

    private var groups: [ActivityBucket] {
        let cal = Calendar.current
        let now = Date()
        var buckets: [String: [ActivityItem]] = [:]
        var order: [String] = []

        for item in items.sorted(by: { $0.timestamp > $1.timestamp }) {
            let label = bucketLabel(for: item.timestamp, now: now, cal: cal)
            if buckets[label] == nil { order.append(label); buckets[label] = [] }
            buckets[label]?.append(item)
        }
        return order.map { ActivityBucket(label: $0, items: buckets[$0]!) }
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.dateFormat = "MMMM"
        return f
    }()

    private static let monthYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    private func bucketLabel(for date: Date, now: Date, cal: Calendar) -> String {
        if cal.isDateInToday(date)     { return "Hoy" }
        if cal.isDateInYesterday(date) { return "Ayer" }
        if let w = cal.date(byAdding: .day, value: -7, to: now), date > w { return "Esta semana" }
        if let m = cal.date(byAdding: .month, value: -1, to: now), date > m { return "Este mes" }

        let f = cal.isDate(date, equalTo: now, toGranularity: .year)
            ? Self.monthFormatter
            : Self.monthYearFormatter
        return f.string(from: date).capitalized
    }
}

struct ActivityRowView: View {
    let item: ActivityItem
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: RuulSpacing.s3) {
            Group {
                if let icon = item.icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(item.kind == .neutral ? accent : item.kind.color)
                        .frame(width: 18, height: 18)
                } else {
                    Circle()
                        .fill(item.kind == .neutral ? accent : item.kind.color)
                        .frame(width: 8, height: 8)
                        .padding(5)
                }
            }
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: RuulSpacing.s0_5) {
                Text(item.title).font(.subheadline)
                if let s = item.subtitle {
                    Text(s).font(.caption).foregroundStyle(Color.ruulTextSecondary)
                }
            }

            Spacer(minLength: 8)

            Text(item.prebakedRelativeTime ?? relativeTime(item.timestamp))
                .font(.caption)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.top, RuulSpacing.s0_5)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, RuulSpacing.s3)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.unitsStyle = .short
        return f
    }()

    private func relativeTime(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

struct ActivityEmptyView: View {
    var body: some View {
        ContentUnavailableView(
            "Sin actividad aún",
            systemImage: "clock.arrow.circlepath",
            description: Text("Las acciones aparecerán aquí.")
        )
        .frame(maxWidth: .infinity)
        .background(Color.ruulSurface)
        .clipShape(RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
    }
}

struct ActivityErrorView: View {
    let message: String
    let accent: Color
    let retry: () -> Void

    var body: some View {
        VStack(spacing: RuulSpacing.s4) {
            ContentUnavailableView(
                "No pudimos cargar la actividad",
                systemImage: "exclamationmark.triangle.fill",
                description: Text(message)
            )

            Button(action: retry) {
                Label("Reintentar", systemImage: "arrow.clockwise")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.glass)
            .tint(accent)
            .padding(.bottom, RuulSpacing.s6)
        }
        .frame(maxWidth: .infinity)
        .background(Color.ruulSurface)
        .clipShape(RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
    }
}

struct ActivitySkeletonView: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        VStack(spacing: RuulSpacing.s0) {
            ForEach(0..<3, id: \.self) { i in
                HStack(spacing: RuulSpacing.s3) {
                    Circle().fill(Color.ruulSurfaceGlassThin).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: RuulSpacing.micro) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.ruulSurfaceGlassThin)
                            .frame(height: 12).frame(maxWidth: 180)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.ruulSurfaceGlassThin)
                            .frame(height: 9).frame(maxWidth: 80)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, RuulSpacing.s3)
                if i < 2 { Divider().padding(.leading, 36) }
            }
        }
        .background(Color.ruulSurface)
        .clipShape(RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
        .redacted(reason: .placeholder)
    }
}

// MARK: ════════════════════════════════════════════════════════════════════
// MARK: 5. CONFIGURACIONES POR TIPO DE RECURSO (ejemplos)
// MARK: ════════════════════════════════════════════════════════════════════

// Modelos de ejemplo (REEMPLAZAR con los del dominio real vía un adapter)
// Renombrados con sufijo `Input` para no chocar con RuulCore.Event / RuulCore.Fund.

public struct EventInput {
    public let id: String
    public let title: String
    public let dateLabel: String        // "21 may"
    public let timeLabel: String        // "2:03 p.m."
    public let dayLabel: String         // "Hoy"
    public let durationMin: Int
    public let isHost: Bool
    /// True when the viewer hasn't accepted yet (no RSVP or pending).
    /// Drives the conditional "Confirma asistencia" primary action.
    public let needsRSVPConfirm: Bool
    /// True when the viewer has already RSVP'd `.going`. Swaps the first
    /// action for "Cancelar asistencia" (destructive tint).
    public let viewerIsGoing: Bool
    /// True when the viewer holds the `issue_manual_fine` permission.
    /// Drives the conditional "Multa manual" item in the toolbar menu.
    public let canIssueManualFine: Bool
    public let address: String
    public let coordinate: CLLocationCoordinate2D
    public let attendees: [Person]
    public let activity: [ActivityItem]
    /// True when the event was generated from a recurring `ResourceSeries`.
    /// Drives the "Recurrente" badge in `IdentitySlot`. One-off events
    /// keep this false.
    public let isRecurrent: Bool
    /// Pre-formatted recurrence cadence label ("Recurrente · Semanal",
    /// "Recurrente · Mensual · Ciclo 3"). nil for one-off events.
    public let recurrenceLabel: String?

    public init(
        id: String,
        title: String,
        dateLabel: String,
        timeLabel: String,
        dayLabel: String,
        durationMin: Int,
        isHost: Bool,
        needsRSVPConfirm: Bool = false,
        viewerIsGoing: Bool = false,
        canIssueManualFine: Bool = false,
        address: String,
        coordinate: CLLocationCoordinate2D,
        attendees: [Person],
        activity: [ActivityItem],
        isRecurrent: Bool = false,
        recurrenceLabel: String? = nil
    ) {
        self.id = id
        self.title = title
        self.dateLabel = dateLabel
        self.timeLabel = timeLabel
        self.dayLabel = dayLabel
        self.durationMin = durationMin
        self.isHost = isHost
        self.needsRSVPConfirm = needsRSVPConfirm
        self.viewerIsGoing = viewerIsGoing
        self.canIssueManualFine = canIssueManualFine
        self.address = address
        self.coordinate = coordinate
        self.attendees = attendees
        self.activity = activity
        self.isRecurrent = isRecurrent
        self.recurrenceLabel = recurrenceLabel
    }
}

public struct FundInput {
    public let id: String
    public let name: String
    public let createdAgo: String       // "hace 2 d"
    public let balance: Decimal
    public let contributed: Decimal
    public let withdrawn: Decimal
    public let participants: [Person]
    public let movements: [ActivityItem]

    public init(
        id: String,
        name: String,
        createdAgo: String,
        balance: Decimal,
        contributed: Decimal,
        withdrawn: Decimal,
        participants: [Person],
        movements: [ActivityItem]
    ) {
        self.id = id
        self.name = name
        self.createdAgo = createdAgo
        self.balance = balance
        self.contributed = contributed
        self.withdrawn = withdrawn
        self.participants = participants
        self.movements = movements
    }
}

public struct VoteInput {
    public let id: String
    public let title: String
    public let description: String?
    public let statusLabel: String        // "Abierta", "Resuelta · Aprobada", "Cancelada"
    public let voteTypeLabel: String       // "Apelación de multa", "Cambio de regla", etc.
    public let timingLabel: String         // "Cierra en 2 d", "Cerró hace 1 d"
    public let inFavor: Int
    public let against: Int
    public let abstained: Int
    public let totalEligible: Int
    public let quorumPercent: Int
    public let thresholdPercent: Int
    public let viewerAlreadyVoted: Bool
    public let activity: [ActivityItem]

    public init(
        id: String,
        title: String,
        description: String?,
        statusLabel: String,
        voteTypeLabel: String,
        timingLabel: String,
        inFavor: Int,
        against: Int,
        abstained: Int,
        totalEligible: Int,
        quorumPercent: Int,
        thresholdPercent: Int,
        viewerAlreadyVoted: Bool,
        activity: [ActivityItem]
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.statusLabel = statusLabel
        self.voteTypeLabel = voteTypeLabel
        self.timingLabel = timingLabel
        self.inFavor = inFavor
        self.against = against
        self.abstained = abstained
        self.totalEligible = totalEligible
        self.quorumPercent = quorumPercent
        self.thresholdPercent = thresholdPercent
        self.viewerAlreadyVoted = viewerAlreadyVoted
        self.activity = activity
    }
}

public struct FineInput {
    public let id: String
    public let reason: String
    public let amountFormatted: String
    public let statusLabel: String
    public let createdAtLabel: String
    public let issuedByName: String?
    public let canPay: Bool
    public let canAppeal: Bool
    public let appealStatusLabel: String?
    public let activity: [ActivityItem]

    public init(
        id: String,
        reason: String,
        amountFormatted: String,
        statusLabel: String,
        createdAtLabel: String,
        issuedByName: String?,
        canPay: Bool,
        canAppeal: Bool,
        appealStatusLabel: String?,
        activity: [ActivityItem]
    ) {
        self.id = id
        self.reason = reason
        self.amountFormatted = amountFormatted
        self.statusLabel = statusLabel
        self.createdAtLabel = createdAtLabel
        self.issuedByName = issuedByName
        self.canPay = canPay
        self.canAppeal = canAppeal
        self.appealStatusLabel = appealStatusLabel
        self.activity = activity
    }
}

public struct SpaceInput {
    public let id: String
    public let name: String
    public let isActive: Bool
    public let capacity: Int
    public let location: String
    public let bookingsThisMonth: Int
    public let nextBookingTime: String?
    public let activity: [ActivityItem]

    public init(
        id: String,
        name: String,
        isActive: Bool,
        capacity: Int,
        location: String,
        bookingsThisMonth: Int,
        nextBookingTime: String?,
        activity: [ActivityItem]
    ) {
        self.id = id
        self.name = name
        self.isActive = isActive
        self.capacity = capacity
        self.location = location
        self.bookingsThisMonth = bookingsThisMonth
        self.nextBookingTime = nextBookingTime
        self.activity = activity
    }
}

public extension ResourceConfig {

    // MARK: Evento

    static func event(
        _ event: EventInput,
        onInvite: @escaping () -> Void = {},
        onEdit: @escaping () -> Void = {},
        onRotateHost: @escaping () -> Void = {},
        onSeeAllAttendees: @escaping () -> Void = {},
        onRSVPConfirm: @escaping () -> Void = {},
        onRSVPCancel: @escaping () -> Void = {},
        onAddToCalendar: @escaping () -> Void = {},
        toolbarMenu: [ToolbarMenuItem] = []
    ) -> ResourceConfig {
        let accent = ResourceFamilyTint.events.color

        // Actions row, capped at 3. RSVP state takes precedence over the
        // host workflow: an event creator is still an attendee until they
        // confirm, and the old surface showed "Sin tu respuesta aún" for
        // hosts who hadn't yet RSVP'd themselves. So:
        //   - Anyone with no RSVP / pending:
        //        [Confirma asistencia (success), Invitar, Editar]   if host
        //        [Confirma asistencia, Compartir, Calendario]       otherwise
        //   - Anyone going + host: [Invitar, Editar, Rotar]
        //   - Anyone going + non-host: [Cancelar (error), Compartir, Calendario]
        //   - Declined / closed + non-host: [Compartir, Calendario]
        let actions: [ResourceAction]
        if event.needsRSVPConfirm {
            let confirm = ResourceAction(
                label: "Confirma asistencia",
                icon: "checkmark",
                tint: .ruulSemanticSuccess,
                handler: onRSVPConfirm
            )
            if event.isHost {
                actions = [
                    confirm,
                    ResourceAction(label: "Invitar", icon: "plus", tint: accent, handler: onInvite),
                    ResourceAction(label: "Editar", handler: onEdit)
                ]
            } else {
                actions = [
                    confirm,
                    ResourceAction(label: "Compartir", icon: "square.and.arrow.up", handler: onInvite),
                    ResourceAction(label: "Calendario", icon: "calendar.badge.plus", handler: onAddToCalendar)
                ]
            }
        } else if event.isHost {
            actions = [
                ResourceAction(label: "Invitar", icon: "plus", tint: accent, handler: onInvite),
                ResourceAction(label: "Editar", handler: onEdit),
                ResourceAction(label: "Rotar", handler: onRotateHost)
            ]
        } else if event.viewerIsGoing {
            actions = [
                ResourceAction(label: "Cancelar", icon: "xmark", tint: .ruulSemanticError, handler: onRSVPCancel),
                ResourceAction(label: "Compartir", icon: "square.and.arrow.up", handler: onInvite),
                ResourceAction(label: "Calendario", icon: "calendar.badge.plus", handler: onAddToCalendar)
            ]
        } else {
            actions = [
                ResourceAction(label: "Compartir", icon: "square.and.arrow.up", handler: onInvite),
                ResourceAction(label: "Calendario", icon: "calendar.badge.plus", handler: onAddToCalendar)
            ]
        }

        // Metadata under the title — adds the recurrence cadence so the
        // viewer can tell a one-off from a recurring instance at a glance.
        var identityMetadata: [String] = [event.dayLabel]
        if let recurrence = event.recurrenceLabel {
            identityMetadata.append(recurrence)
        } else if event.isRecurrent {
            identityMetadata.append("Recurrente")
        }

        // When recurrent, prepend a "Detalles" row section so the cadence
        // is also a tappable / scannable property, not just a tag.
        var sections: [ResourceSection] = []
        if let recurrence = event.recurrenceLabel ?? (event.isRecurrent ? "Recurrente" : nil) {
            sections.append(.rows(title: "Detalles", items: [
                RowItem(icon: "arrow.triangle.2.circlepath", label: "Recurrencia", value: .text(recurrence))
            ]))
        }
        sections.append(contentsOf: [
            .map(
                title: "Lugar",
                location: MapLocation(
                    coordinate: event.coordinate,
                    address: event.address
                )
            ),
            .avatars(
                title: "Asistencia",
                people: event.attendees,
                emptyText: "Aún nadie invitado",
                onTapMore: onSeeAllAttendees
            )
        ])

        return ResourceConfig(
            identity: IdentityData(
                iconSystemName: "calendar",
                name: event.title,
                typeLabel: "Evento",
                metadata: identityMetadata,
                badge: event.isHost ? ResourceBadge(text: "Anfitrión", color: accent) : nil
            ),
            accent: accent,
            hero: HeroData(
                value: event.timeLabel,
                label: "\(event.dateLabel) · \(event.durationMin) min de duración",
                size: .title
            ),
            actions: actions,
            sections: sections,
            activity: .static(event.activity),
            toolbarMenu: toolbarMenu
        )
    }

    // MARK: Fondo

    static func fund(
        _ fund: FundInput,
        onContribute: @escaping () -> Void = {},
        onWithdraw: @escaping () -> Void = {},
        onSeeLedger: @escaping () -> Void = {},
        onSeeParticipants: @escaping () -> Void = {},
        activityLoader: ActivityLoader? = nil
    ) -> ResourceConfig {
        let movementsSection: ResourceSection = fund.movements.isEmpty
            ? .empty(
                title: "Movimientos",
                icon: "tray",
                message: "Sin movimientos aún",
                description: "Registra el primero para empezar a ver el historial."
            )
            : .rows(title: "Movimientos", items: fund.movements.prefix(5).map { item in
                RowItem(
                    icon: item.icon,
                    label: item.title,
                    value: .text(item.subtitle ?? "")
                )
            })

        let accent = ResourceFamilyTint.funds.color
        return ResourceConfig(
            identity: IdentityData(
                iconSystemName: "banknote",
                name: fund.name,
                typeLabel: "Fondo",
                metadata: ["Creado \(fund.createdAgo)"]
            ),
            accent: accent,
            hero: HeroData(
                value: fund.balance.formatted(.currency(code: "MXN")),
                label: "Saldo en MXN",
                size: .display,
                subRow: [
                    ("Aportado", fund.contributed.formatted(.currency(code: "MXN"))),
                    ("Retirado", fund.withdrawn.formatted(.currency(code: "MXN")))
                ]
            ),
            actions: [
                ResourceAction(label: "Aportar", icon: "arrow.down", tint: .ruulSemanticSuccess, handler: onContribute),
                ResourceAction(label: "Retirar", icon: "arrow.up", tint: .ruulSemanticError, handler: onWithdraw),
                ResourceAction(label: "Libro", handler: onSeeLedger)
            ],
            sections: [
                movementsSection,
                .avatars(
                    title: "Participantes",
                    people: fund.participants,
                    emptyText: nil,
                    onTapMore: onSeeParticipants
                )
            ],
            activity: activityLoader.map { .paginated($0) } ?? .static(fund.movements),
            toolbarMenu: [
                ToolbarMenuItem(label: "Exportar libro", icon: "square.and.arrow.up", handler: {}),
                ToolbarMenuItem(label: "Editar fondo", icon: "pencil", handler: {}),
                ToolbarMenuItem(label: "Cerrar fondo", icon: "lock", role: .destructive, handler: {})
            ]
        )
    }

    // MARK: Votación

    /// Renders a Vote with results breakdown (a-favor / en-contra /
    /// abstención / total elegibles) plus the decision rules section
    /// (quórum + mayoría). The cast picker opens via `onCast` from the
    /// inline action; admin finalize/cancel land in `toolbarMenu` and
    /// stay gated by the host.
    static func vote(
        _ vote: VoteInput,
        onCast: @escaping () -> Void = {},
        toolbarMenu: [ToolbarMenuItem] = []
    ) -> ResourceConfig {
        let accent = ResourceFamilyTint.votes.color
        let actions: [ResourceAction] = vote.viewerAlreadyVoted ? [] : [
            ResourceAction(label: "Emitir voto", icon: "checkmark.seal", tint: accent, handler: onCast)
        ]
        var sections: [ResourceSection] = []
        if vote.totalEligible > 0 {
            sections.append(.rows(title: "Resultados", items: [
                RowItem(icon: "hand.thumbsup",   label: "A favor",        value: .text("\(vote.inFavor)")),
                RowItem(icon: "hand.thumbsdown", label: "En contra",      value: .text("\(vote.against)")),
                RowItem(icon: "minus.circle",    label: "Abstención",     value: .text("\(vote.abstained)")),
                RowItem(icon: "person.3",        label: "Total elegibles",value: .text("\(vote.totalEligible)"))
            ]))
        }
        sections.append(.rows(title: "Reglas de decisión", items: [
            RowItem(icon: "checkmark.shield", label: "Quórum",            value: .text("\(vote.quorumPercent)%")),
            RowItem(icon: "scale.3d",         label: "Mayoría requerida", value: .text("\(vote.thresholdPercent)%"))
        ]))
        return ResourceConfig(
            identity: IdentityData(
                iconSystemName: "checkmark.seal",
                name: vote.title,
                typeLabel: "Votación",
                metadata: [vote.voteTypeLabel],
                badge: nil
            ),
            accent: accent,
            hero: HeroData(
                value: vote.statusLabel,
                label: vote.timingLabel,
                size: .title
            ),
            actions: actions,
            sections: sections,
            activity: .static(vote.activity),
            toolbarMenu: toolbarMenu
        )
    }

    // MARK: Multa

    /// Renders a Fine with the amount as the dominant hero metric +
    /// status as label. Pay / Appeal lives inline as gated actions;
    /// admin "Anular" lands in `toolbarMenu`. Detail rows expose
    /// reason, emisor, and timing; an "Apelación" section only renders
    /// when `appealStatusLabel` is set.
    static func fine(
        _ fine: FineInput,
        onPay: @escaping () -> Void = {},
        onAppeal: @escaping () -> Void = {},
        toolbarMenu: [ToolbarMenuItem] = []
    ) -> ResourceConfig {
        let accent = ResourceFamilyTint.fines.color
        var actions: [ResourceAction] = []
        if fine.canPay {
            actions.append(ResourceAction(label: "Pagar", icon: "creditcard", tint: .ruulSemanticSuccess, handler: onPay))
        }
        if fine.canAppeal {
            actions.append(ResourceAction(label: "Apelar", icon: "exclamationmark.bubble", handler: onAppeal))
        }
        var detailRows: [RowItem] = [
            RowItem(icon: "doc.text", label: "Razón",   value: .text(fine.reason)),
            RowItem(icon: "calendar", label: "Emitida", value: .text(fine.createdAtLabel))
        ]
        if let issuer = fine.issuedByName {
            detailRows.append(RowItem(icon: "person", label: "Emisor", value: .text(issuer)))
        }
        var sections: [ResourceSection] = [
            .rows(title: "Detalles", items: detailRows)
        ]
        if let appealLabel = fine.appealStatusLabel {
            sections.append(.rows(title: "Apelación", items: [
                RowItem(icon: "exclamationmark.bubble", label: "Estado", value: .text(appealLabel))
            ]))
        }
        return ResourceConfig(
            identity: IdentityData(
                iconSystemName: "exclamationmark.bubble",
                name: fine.reason,
                typeLabel: "Multa",
                metadata: [fine.statusLabel],
                badge: nil
            ),
            accent: accent,
            hero: HeroData(
                value: fine.amountFormatted,
                label: fine.statusLabel,
                size: .display
            ),
            actions: actions,
            sections: sections,
            activity: .static(fine.activity),
            toolbarMenu: toolbarMenu
        )
    }

    // MARK: Espacio

    static func space(
        _ space: SpaceInput,
        onReserve: @escaping () -> Void = {},
        onSeeCalendar: @escaping () -> Void = {},
        onEdit: @escaping () -> Void = {}
    ) -> ResourceConfig {
        let accent = ResourceFamilyTint.assets.color
        return ResourceConfig(
            identity: IdentityData(
                iconSystemName: "key.fill",
                name: space.name,
                typeLabel: "Espacio",
                badge: space.isActive ? ResourceBadge(text: "Activo", color: .ruulSemanticSuccess) : nil
            ),
            accent: accent,
            hero: HeroData(
                value: space.nextBookingTime ?? "Disponible",
                label: space.nextBookingTime == nil
                    ? "Sin reservas próximas"
                    : "Próxima reserva",
                size: .title
            ),
            actions: [
                ResourceAction(label: "Reservar", icon: "calendar.badge.plus", tint: accent, handler: onReserve),
                ResourceAction(label: "Calendario", handler: onSeeCalendar),
                ResourceAction(label: "Editar", handler: onEdit)
            ],
            sections: [
                .rows(title: "Detalles", items: [
                    RowItem(icon: "person.2", label: "Capacidad", value: .text("\(space.capacity) personas")),
                    RowItem(icon: "mappin", label: "Ubicación", value: .text(space.location)),
                    RowItem(icon: "star", label: "Reservas", value: .text("\(space.bookingsThisMonth) este mes"))
                ]),
                .empty(
                    title: "Próximas reservas",
                    icon: "calendar",
                    message: "Sin reservas próximas",
                    description: "Toca Reservar para apartar este espacio."
                )
            ],
            activity: .static(space.activity)
        )
    }
}

// MARK: ════════════════════════════════════════════════════════════════════
// MARK: 6. PREVIEW
// MARK: ════════════════════════════════════════════════════════════════════

#if DEBUG
#Preview("Evento") {
    ResourceDetailView(config: .event(EventInput(
        id: "1",
        title: "Rrff",
        dateLabel: "21 may",
        timeLabel: "2:03 p.m.",
        dayLabel: "Hoy",
        durationMin: 180,
        isHost: true,
        address: "Altezza Bosques, Camino a Tecamachalco 98, El Olivo, 52789 Naucalpan, Edo. Méx.",
        coordinate: CLLocationCoordinate2D(latitude: 19.4019, longitude: -99.2436),
        attendees: [],
        activity: [
            ActivityItem(id: "a1", title: "Confirmación de asistencia",
                         subtitle: "Tú", timestamp: Date().addingTimeInterval(-36000),
                         kind: .positive),
            ActivityItem(id: "a2", title: "Evento creado",
                         subtitle: "Tú", timestamp: Date().addingTimeInterval(-36000))
        ]
    )))
}

#Preview("Fondo") {
    ResourceDetailView(config: .fund(FundInput(
        id: "1",
        name: "Nabba",
        createdAgo: "hace 2 d",
        balance: 0,
        contributed: 0,
        withdrawn: 0,
        participants: [
            Person(id: "p1", name: "Jose", initials: "JM", color: .orange),
            Person(id: "p2", name: "Linda", initials: "LR", color: .indigo)
        ],
        movements: []
    )))
}

#Preview("Espacio") {
    ResourceDetailView(config: .space(SpaceInput(
        id: "1",
        name: "Palco",
        isActive: true,
        capacity: 12,
        location: "Nivel 2 · Norte",
        bookingsThisMonth: 0,
        nextBookingTime: nil,
        activity: [
            ActivityItem(id: "s1", title: "Espacio creado",
                         subtitle: "Tú",
                         timestamp: Date().addingTimeInterval(-172800))
        ]
    )))
}

#Preview("Votación") {
    ResourceDetailView(config: .vote(VoteInput(
        id: "1",
        title: "¿Subimos la cuota mensual a $500?",
        description: "Para cubrir gastos del próximo trimestre.",
        statusLabel: "Abierta",
        voteTypeLabel: "Cambio de regla",
        timingLabel: "Cierra en 2 d",
        inFavor: 4,
        against: 1,
        abstained: 1,
        totalEligible: 8,
        quorumPercent: 60,
        thresholdPercent: 50,
        viewerAlreadyVoted: false,
        activity: [
            ActivityItem(id: "v1", title: "Votación iniciada",
                         subtitle: "Jose", timestamp: Date().addingTimeInterval(-7200)),
            ActivityItem(id: "v2", title: "Voto emitido",
                         subtitle: "Linda · A favor",
                         timestamp: Date().addingTimeInterval(-3600),
                         kind: .positive)
        ]
    )))
}

#Preview("Multa") {
    ResourceDetailView(config: .fine(FineInput(
        id: "1",
        reason: "Llegada tarde a la cena",
        amountFormatted: "$200.00",
        statusLabel: "Pendiente",
        createdAtLabel: "Hoy · 21 may",
        issuedByName: "Jose",
        canPay: true,
        canAppeal: true,
        appealStatusLabel: nil,
        activity: [
            ActivityItem(id: "f1", title: "Multa emitida",
                         subtitle: "Jose", timestamp: Date().addingTimeInterval(-1800),
                         kind: .negative)
        ]
    )))
}
#endif
