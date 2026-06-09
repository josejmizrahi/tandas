import SwiftUI
import RuulCore

/// F.6 — lista de recursos visibles del contexto.
///
/// **R.5V.X (2026-06-09)** — Rebuild Apple-native + Liquid Glass (mismo patrón
/// que MyResourcesView v3, ahora paridad per-context):
/// 1. Hero Liquid Glass: count + breakdown chips por clase
/// 2. `.searchable` para filtrar por nombre
/// 3. Sections por clase (Bienes raíces / Finanzas / Vehículos / etc.) con
///    tints semánticos
/// 4. Reservations entry section preservada (solo collective)
/// 5. Estados Ruul* (Loading/Error/Empty)
public struct ResourcesListView: View {
    let context: AppContext
    let container: DependencyContainer

    @State private var store: ResourcesStore
    @State private var isShowingCreate = false
    @State private var query: String = ""
    /// R.5V.Zoom — Namespace para matched transition source → destination zoom.
    @Namespace private var zoomNamespace

    public init(context: AppContext, container: DependencyContainer) {
        self.context = context
        self.container = container
        _store = State(initialValue: ResourcesStore(rpc: container.rpc))
    }

    public var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                RuulLoadingState(title: "Cargando recursos…")
            case .failed(let message):
                RuulErrorState(message: message) {
                    Task { await store.load(context: context) }
                }
            case .loaded:
                resourcesList
            }
        }
        .navigationTitle("Recursos")
        .task {
            await store.load(context: context)
        }
        .refreshable {
            await store.load(context: context)
        }
        .refreshOnReappear(if: store.phase.isLoaded) {
            await store.load(context: context)
        }
        .toolbar {
            if store.canCreate(in: context) {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingCreate = true
                    } label: {
                        Label("Crear recurso", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingCreate) {
            // P1 fix 2026-06-08: usar CreateResourceFlow (Subtype Picker UX D shipped)
            // en vez del legacy CreateResourceView que tenía bugs en el path 10-arg.
            CreateResourceFlow(context: context, store: store, container: container)
        }
    }

    @ViewBuilder
    private var resourcesList: some View {
        if context.isPersonal {
            personalResourcesList
        } else {
            contextResourcesList
        }
    }

    // MARK: - Personal mode (MyWorldResource — cross-context que el actor personal ve)

    @ViewBuilder
    private var personalResourcesList: some View {
        if store.personalResources.isEmpty {
            RuulEmptyState(
                title: "Sin recursos",
                systemImage: "shippingbox",
                message: "Nadie te ha compartido recursos todavía."
            )
        } else {
            let filtered = filterPersonal(store.personalResources)
            let grouped = Dictionary(grouping: filtered, by: { ResourceClassGroup.from($0.resourceType) })
                .mapValues { $0.sorted { $0.displayName < $1.displayName } }
            List {
                heroSectionPersonal(store.personalResources)
                ForEach(ResourceClassGroup.displayOrder, id: \.self) { klass in
                    if let items = grouped[klass], !items.isEmpty {
                        Section {
                            ForEach(items) { resource in
                                personalRow(resource, klass: klass)
                            }
                        } header: {
                            HStack {
                                Label(klass.displayName, systemImage: klass.symbolName)
                                    .foregroundStyle(Theme.Text.secondary)
                                Spacer()
                                Text("\(items.count)").foregroundStyle(Theme.Text.tertiary)
                            }
                        }
                    }
                }
                if grouped.isEmpty {
                    noMatchesSection
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Buscar recurso")
        }
    }

    @ViewBuilder
    private func personalRow(_ resource: MyWorldResource, klass: ResourceClassGroup) -> some View {
        NavigationLink {
            ResourceDetailViewV2(resourceId: resource.resourceId, context: context, container: container)
                .navigationTransition(.zoom(sourceID: resource.resourceId, in: zoomNamespace))
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(resource.displayName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.Text.primary)
                    if !resource.reasons.isEmpty {
                        Text(resource.reasons.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(Theme.Text.secondary)
                            .lineLimit(1)
                    }
                }
            } icon: {
                Image(systemName: (ResourceType(rawValue: resource.resourceType) ?? .other).symbolName)
                    .foregroundStyle(klass.tint)
            }
        }
        .matchedTransitionSource(id: resource.resourceId, in: zoomNamespace)
    }

    // MARK: - Context mode (ContextResource — gobernados por el contexto colectivo)

    @ViewBuilder
    private var contextResourcesList: some View {
        if store.resources.isEmpty {
            List {
                reservationsEntry
                Section {
                    RuulEmptyState(
                        title: "Sin recursos",
                        systemImage: "shippingbox",
                        message: "Registra una casa, un fondo común, un coche o cualquier cosa que este contexto gobierne."
                    )
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
        } else {
            let filtered = filterContext(store.resources)
            let grouped = Dictionary(grouping: filtered, by: { ResourceClassGroup.from($0.resourceType) })
                .mapValues { $0.sorted { $0.displayName < $1.displayName } }
            List {
                heroSectionContext(store.resources)
                reservationsEntry
                ForEach(ResourceClassGroup.displayOrder, id: \.self) { klass in
                    if let items = grouped[klass], !items.isEmpty {
                        Section {
                            ForEach(items) { resource in
                                contextRow(resource, klass: klass)
                            }
                        } header: {
                            HStack {
                                Label(klass.displayName, systemImage: klass.symbolName)
                                    .foregroundStyle(Theme.Text.secondary)
                                Spacer()
                                Text("\(items.count)").foregroundStyle(Theme.Text.tertiary)
                            }
                        }
                    }
                }
                if grouped.isEmpty {
                    noMatchesSection
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Buscar recurso")
        }
    }

    @ViewBuilder
    private func contextRow(_ resource: ContextResource, klass: ResourceClassGroup) -> some View {
        NavigationLink {
            ResourceDetailViewV2(resourceId: resource.resourceId, context: context, container: container)
                .navigationTransition(.zoom(sourceID: resource.resourceId, in: zoomNamespace))
        } label: {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(resource.displayName)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.Text.primary)
                        Text(rightsSummary(resource))
                            .font(.caption)
                            .foregroundStyle(Theme.Text.secondary)
                            .lineLimit(1)
                    }
                } icon: {
                    Image(systemName: resource.type.symbolName)
                        .foregroundStyle(klass.tint)
                }
                Spacer()
                if let value = resource.estimatedValue {
                    Text(value.currencyLabel(resource.currency))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.Text.tertiary)
                }
            }
        }
        .matchedTransitionSource(id: resource.resourceId, in: zoomNamespace)
    }

    // MARK: - Hero (Liquid Glass) — dos overloads por shape (Personal/Context)

    @ViewBuilder
    private func heroSectionPersonal(_ resources: [MyWorldResource]) -> some View {
        let byClass = Dictionary(grouping: resources, by: { ResourceClassGroup.from($0.resourceType) })
        heroSectionShared(
            count: resources.count,
            labelSingular: "recurso visible",
            labelPlural: "recursos visibles",
            countByGroup: byClass.mapValues(\.count)
        )
    }

    @ViewBuilder
    private func heroSectionContext(_ resources: [ContextResource]) -> some View {
        let byClass = Dictionary(grouping: resources, by: { ResourceClassGroup.from($0.resourceType) })
        heroSectionShared(
            count: resources.count,
            labelSingular: "recurso",
            labelPlural: "recursos",
            countByGroup: byClass.mapValues(\.count)
        )
    }

    @ViewBuilder
    private func heroSectionShared(count: Int, labelSingular: String, labelPlural: String, countByGroup: [ResourceClassGroup: Int]) -> some View {
        let breakdown = ResourceClassGroup.displayOrder.compactMap { g -> (ResourceClassGroup, Int)? in
            guard let n = countByGroup[g], n > 0 else { return nil }
            return (g, n)
        }
        Section {
            GlassEffectContainer(spacing: Theme.Spacing.sm) {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                        Text("\(count)")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.Tint.primary)
                        Text(count == 1 ? labelSingular : labelPlural)
                            .font(.callout)
                            .foregroundStyle(Theme.Text.secondary)
                        Spacer(minLength: 0)
                    }
                    if !breakdown.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Theme.Spacing.xs) {
                                ForEach(breakdown, id: \.0) { group, n in
                                    classChip(group, count: n)
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
    private func classChip(_ klass: ResourceClassGroup, count: Int) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: klass.symbolName).font(.caption.weight(.semibold))
            Text("\(count)").font(.caption.weight(.semibold)).monospacedDigit()
        }
        .foregroundStyle(klass.tint)
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(klass.tint.opacity(Theme.Surface.badgeFillSubtle), in: Capsule())
    }

    // MARK: - Reservations entry (preservada — context-only)

    @ViewBuilder
    private var reservationsEntry: some View {
        Section {
            NavigationLink {
                ContextReservationsView(context: context, container: container)
            } label: {
                Label("Reservaciones del contexto", systemImage: "calendar.badge.clock")
            }
        }
    }

    // MARK: - Filter helpers

    private func filterPersonal(_ resources: [MyWorldResource]) -> [MyWorldResource] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return resources }
        return resources.filter { $0.displayName.lowercased().contains(q) }
    }

    private func filterContext(_ resources: [ContextResource]) -> [ContextResource] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return resources }
        return resources.filter { $0.displayName.lowercased().contains(q) }
    }

    @ViewBuilder
    private var noMatchesSection: some View {
        Section {
            Text("Sin coincidencias con \"\(query)\"")
                .font(.callout)
                .foregroundStyle(Theme.Text.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, Theme.Spacing.md)
        }
    }

    /// Resumen corto de quién tiene qué derecho.
    private func rightsSummary(_ resource: ContextResource) -> String {
        let kinds = Set(resource.rights.map(\.rightKind))
        return resource.type.label + (kinds.isEmpty ? "" : " · " + kinds.sorted().joined(separator: ", "))
    }
}

// MARK: - ResourceClassGroup (compartido con MyResourcesView)

/// Misma taxonomía que MyResourcesView. Definida internal acá porque
/// MyResourcesView.ResourceClass es private. Si se reutiliza más, mover a
/// un helper compartido.
private enum ResourceClassGroup: String, CaseIterable, Hashable {
    case realEstate, vehicle, financial, document, equipment, digital, trip, other

    static let displayOrder: [ResourceClassGroup] = [
        .realEstate, .financial, .vehicle, .equipment, .digital, .document, .trip, .other
    ]

    static func from(_ resourceType: String) -> ResourceClassGroup {
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
        case .realEstate: return Theme.Tint.warning
        case .vehicle:    return Theme.Tint.warning
        case .financial:  return Theme.Tint.success
        case .document:   return Theme.Text.secondary
        case .equipment:  return Theme.Tint.warning
        case .digital:    return Theme.Tint.info
        case .trip:       return Theme.Tint.info
        case .other:      return Theme.Text.secondary
        }
    }
}

#Preview("Recursos") {
    NavigationStack {
        ResourcesListView(
            context: AppContext(
                id: MockRuulRPCClient.DemoIds.familia,
                kind: .collective,
                subtype: "family",
                displayName: "Familia Mizrahi",
                roles: ["admin"]
            ),
            container: .demo()
        )
    }
}
