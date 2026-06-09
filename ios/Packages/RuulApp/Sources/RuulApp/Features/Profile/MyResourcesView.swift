import SwiftUI
import RuulCore

/// F.NAV.8 — Vista plana cross-context de recursos visibles para el caller.
///
/// **R.5V.X (2026-06-08)** — Rebuild Apple-native + Liquid Glass:
/// 1. Hero summary card con Liquid Glass interactivo (total + breakdown por
///    clase). Mismo glass que dashboard widgets en ResourceDetailViewV2.
/// 2. `.searchable` para filtrar por nombre.
/// 3. Sections agrupadas por clase (Bienes raíces / Vehículos / Finanzas /
///    Documentos / Equipos / Activos digitales / Viajes / Otros) con tints
///    semánticos del Theme.Tint catalog.
/// 4. Reasons como chips inline (USE / GOVERN via Familia / etc.) — antes
///    eran texto monolítico comma-separated.
/// 5. Estados via componentes Ruul* (RuulLoadingState / RuulErrorState /
///    RuulEmptyState) — drop-in replacements de StateViews.swift legacy.
/// 6. Navegación: mantiene v1 ResourceDetailView (la entry cross-context aún
///    no tiene context_actor_id real desde my_world() — V2 valida estricto y
///    rompe con el atajo collective ?? personal).
public struct MyResourcesView: View {
    let container: DependencyContainer

    @State private var world: MyWorld?
    @State private var phase: StorePhase = .idle
    @State private var selectedResource: NavigationTarget?
    @State private var query: String = ""

    public init(container: DependencyContainer) {
        self.container = container
    }

    public var body: some View {
        Group {
            switch phase {
            case .idle, .loading:
                RuulLoadingState(title: "Cargando recursos…")
            case .failed(let message):
                RuulErrorState(message: message) {
                    Task { await load() }
                }
            case .loaded:
                if let world {
                    loadedContent(world)
                }
            }
        }
        .navigationTitle("Mis recursos")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $selectedResource) { target in
            NavigationStack {
                // Cross-context shortcut — usa v1 hasta que my_world()
                // devuelva context_actor_id real por recurso.
                ResourceDetailView(
                    resourceId: target.resourceId,
                    context: target.context,
                    container: container
                )
            }
        }
    }

    // MARK: - Loaded content

    @ViewBuilder
    private func loadedContent(_ world: MyWorld) -> some View {
        if world.resources.isEmpty {
            RuulEmptyState(
                title: "Sin recursos",
                systemImage: "shippingbox",
                message: "Aún no tienes ni puedes ver recursos en tus contextos."
            )
        } else {
            let grouped = groupByClass(filter(world.resources))
            List {
                heroSection(world.resources)
                ForEach(ResourceClass.displayOrder, id: \.self) { klass in
                    if let items = grouped[klass], !items.isEmpty {
                        classSection(klass, items: items)
                    }
                }
                if grouped.isEmpty {
                    Section {
                        Text("Sin coincidencias con \"\(query)\"")
                            .font(.callout)
                            .foregroundStyle(Theme.Text.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, Theme.Spacing.md)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Buscar recurso")
        }
    }

    // MARK: - Hero (Liquid Glass summary)

    @ViewBuilder
    private func heroSection(_ resources: [MyWorldResource]) -> some View {
        let byClass = Dictionary(grouping: resources, by: { ResourceClass.from($0.resourceType) })
        let breakdown = ResourceClass.displayOrder
            .compactMap { klass -> (ResourceClass, Int)? in
                guard let count = byClass[klass]?.count, count > 0 else { return nil }
                return (klass, count)
            }
        Section {
            GlassEffectContainer(spacing: Theme.Spacing.sm) {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                        Text("\(resources.count)")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.Tint.primary)
                        Text(resources.count == 1 ? "recurso visible" : "recursos visibles")
                            .font(.callout)
                            .foregroundStyle(Theme.Text.secondary)
                        Spacer(minLength: 0)
                    }
                    if !breakdown.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Theme.Spacing.xs) {
                                ForEach(breakdown, id: \.0) { klass, count in
                                    classChip(klass, count: count)
                                }
                            }
                        }
                    }
                }
                .padding(Theme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: Theme.Spacing.md, leading: Theme.Spacing.lg, bottom: Theme.Spacing.md, trailing: Theme.Spacing.lg))
        }
    }

    @ViewBuilder
    private func classChip(_ klass: ResourceClass, count: Int) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: klass.symbolName)
                .font(.caption.weight(.semibold))
            Text("\(count)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(klass.tint)
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(klass.tint.opacity(Theme.Surface.badgeFillSubtle), in: Capsule())
    }

    // MARK: - Class section

    @ViewBuilder
    private func classSection(_ klass: ResourceClass, items: [MyWorldResource]) -> some View {
        Section {
            ForEach(items) { resource in
                Button {
                    openResource(resource)
                } label: {
                    resourceRow(resource, klass: klass)
                }
            }
        } header: {
            Label(klass.displayName, systemImage: klass.symbolName)
                .foregroundStyle(Theme.Text.secondary)
        }
    }

    @ViewBuilder
    private func resourceRow(_ resource: MyWorldResource, klass: ResourceClass) -> some View {
        Label {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(resource.displayName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                if !resource.reasons.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.Spacing.xs) {
                            ForEach(Array(resource.reasons.enumerated()), id: \.offset) { _, reason in
                                reasonChip(reason)
                            }
                        }
                    }
                }
            }
        } icon: {
            Image(systemName: (ResourceType(rawValue: resource.resourceType) ?? .other).symbolName)
                .foregroundStyle(klass.tint)
        }
    }

    @ViewBuilder
    private func reasonChip(_ reason: String) -> some View {
        Text(reason)
            .font(.caption2.weight(.medium))
            .foregroundStyle(Theme.Text.secondary)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(Color.secondary.opacity(Theme.Surface.badgeFillSubtle), in: Capsule())
    }

    // MARK: - Filtering + grouping

    private func filter(_ resources: [MyWorldResource]) -> [MyWorldResource] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return resources }
        return resources.filter { $0.displayName.lowercased().contains(q) }
    }

    private func groupByClass(_ resources: [MyWorldResource]) -> [ResourceClass: [MyWorldResource]] {
        Dictionary(grouping: resources, by: { ResourceClass.from($0.resourceType) })
            .mapValues { $0.sorted { $0.displayName < $1.displayName } }
    }

    // MARK: - Data

    private func load() async {
        if world == nil { phase = .loading }
        do {
            world = try await container.rpc.myWorld()
            phase = .loaded
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }

    private func openResource(_ resource: MyWorldResource) {
        let collective = container.contextStore.availableContexts.first { !$0.isPersonal }
        let personal = container.contextStore.availableContexts.first { $0.isPersonal }
        guard let ctx = collective ?? personal else { return }
        selectedResource = NavigationTarget(resourceId: resource.resourceId, context: ctx)
    }

    struct NavigationTarget: Identifiable, Hashable {
        let resourceId: UUID
        let context: AppContext
        var id: UUID { resourceId }
    }
}

// MARK: - ResourceClass (grouping helper)

private enum ResourceClass: String, CaseIterable, Hashable {
    case realEstate, vehicle, financial, document, equipment, digital, trip, other

    static let displayOrder: [ResourceClass] = [
        .realEstate, .financial, .vehicle, .equipment, .digital, .document, .trip, .other
    ]

    static func from(_ resourceType: String) -> ResourceClass {
        switch resourceType {
        case "house", "property": return .realEstate
        case "vehicle":           return .vehicle
        case "bank_account", "cash_pool", "security", "trust_asset": return .financial
        case "contract", "document": return .document
        case "equipment":         return .equipment
        case "digital_asset":     return .digital
        case "trip_booking":      return .trip
        default:                  return .other
        }
    }

    var displayName: String {
        switch self {
        case .realEstate: return "Bienes raíces"
        case .vehicle:    return "Vehículos"
        case .financial:  return "Finanzas"
        case .document:   return "Documentos"
        case .equipment:  return "Equipos"
        case .digital:    return "Activos digitales"
        case .trip:       return "Viajes"
        case .other:      return "Otros"
        }
    }

    var symbolName: String {
        switch self {
        case .realEstate: return "house.fill"
        case .vehicle:    return "car.fill"
        case .financial:  return "dollarsign.circle.fill"
        case .document:   return "doc.text.fill"
        case .equipment:  return "wrench.and.screwdriver.fill"
        case .digital:    return "externaldrive.fill.badge.icloud"
        case .trip:       return "airplane"
        case .other:      return "shippingbox.fill"
        }
    }

    var tint: Color {
        switch self {
        case .realEstate: return Theme.Tint.warning   // orange — recurso físico
        case .vehicle:    return Theme.Tint.warning   // orange
        case .financial:  return Theme.Tint.success   // green — dinero
        case .document:   return Theme.Text.secondary // neutral
        case .equipment:  return Theme.Tint.warning   // orange
        case .digital:    return Theme.Tint.info      // blue
        case .trip:       return Theme.Tint.info      // blue
        case .other:      return Theme.Text.secondary
        }
    }
}

#Preview("Mis recursos (demo)") {
    NavigationStack {
        MyResourcesView(container: .demo())
    }
}
