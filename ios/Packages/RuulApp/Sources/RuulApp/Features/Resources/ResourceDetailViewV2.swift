import SwiftUI
import RuulCore

/// R.5A.F.1 — ResourceDetailView v2 backed by `resource_detail_descriptor`.
///
/// Render dinámico desde el descriptor (NO `resource_type`):
/// - Hero: subtype.icon + display_name + class badge + status badge
/// - Widgets row horizontal (cards desde `descriptor.widgets[]`)
/// - Sections (`descriptor.sections[]`) renderizadas como cards con header + meta
/// - Actions agrupadas por section, con dangerous tint + confirmation hint
/// - Relations (outbound + inbound) + activity preview
///
/// **F.1 conservador:** vista read-only. La ejecución de acciones (form runtime
/// + dispatcher call) es F.2. Mantener v1 hasta paridad con 7 founder-canon
/// subtypes (primary_residence, vacation_home, warehouse, money_pool,
/// recurring_event, contract, iou).
public struct ResourceDetailViewV2: View {
    let resourceId: UUID
    let context: AppContext
    let container: DependencyContainer

    @State private var store: ResourceDescriptorStore
    /// R.5A.F.2 — action seleccionada para presentar `ResourceActionFormView`.
    @State private var pendingAction: PendingAction?
    /// R.5A cutover — fallback a la vista clásica (v1) cuando V2 aún no cubre
    /// algún flow (edit/settings/grant_right/attach_document).
    @State private var isShowingClassicSheet = false

    public init(resourceId: UUID, context: AppContext, container: DependencyContainer) {
        self.resourceId = resourceId
        self.context = context
        self.container = container
        _store = State(initialValue: ResourceDescriptorStore(rpc: container.rpc))
    }

    /// Wrapper Identifiable para `.sheet(item:)`.
    private struct PendingAction: Identifiable {
        let action: ResourceDescriptorAction
        let form: ResourceActionForm?
        var id: String { action.actionKey }
    }

    public var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                LoadingStateView()
            case .failed(let message):
                ErrorStateView(message: message) {
                    Task { await store.load(resourceId: resourceId) }
                }
            case .loaded:
                if let descriptor = store.descriptor {
                    descriptorScroll(descriptor)
                }
            }
        }
        .navigationTitle(store.descriptor?.resource.displayName ?? "Recurso")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("Fallback") {
                        Button {
                            isShowingClassicSheet = true
                        } label: {
                            Label("Vista clásica", systemImage: "rectangle.stack")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Más opciones")
            }
        }
        .task {
            await store.load(resourceId: resourceId)
        }
        .refreshable {
            await store.load(resourceId: resourceId)
        }
        .sheet(item: $pendingAction) { entry in
            ResourceActionFormView(
                resourceId: resourceId,
                action: entry.action,
                actionForm: entry.form,
                container: container
            ) { _ in
                Task { await store.refreshActions(resourceId: resourceId) }
            }
        }
        .sheet(isPresented: $isShowingClassicSheet) {
            NavigationStack {
                ResourceDetailView(resourceId: resourceId, context: context, container: container)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Cerrar") { isShowingClassicSheet = false }
                        }
                    }
            }
        }
    }

    // MARK: - Scroll body

    @ViewBuilder
    private func descriptorScroll(_ d: ResourceDetailDescriptor) -> some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                heroCard(d)
                if !d.widgets.isEmpty { widgetsRow(d.widgets) }
                if !d.sections.isEmpty { sectionsCard(d) }
                if !d.actions.isEmpty { actionsCard(d) }
                if !d.relations.outbound.isEmpty || !d.relations.inbound.isEmpty {
                    relationsCard(d.relations)
                }
                if !d.activityPreview.isEmpty { activityCard(d.activityPreview) }
                Spacer(minLength: Theme.Spacing.xl)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.top, Theme.Spacing.lg)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    // MARK: - Hero

    @ViewBuilder
    private func heroCard(_ d: ResourceDetailDescriptor) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .center, spacing: Theme.Spacing.md) {
                Image(systemName: d.subtype.icon ?? d.class.icon ?? "cube")
                    .font(.system(size: Theme.IconSize.lg, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: Theme.IconSize.hero, height: Theme.IconSize.hero)
                    .background(Color.accentColor.badgeFillSubtle, in: Theme.cardShape(Theme.Radius.card))
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(d.resource.displayName)
                        .font(.title2.bold())
                    HStack(spacing: Theme.Spacing.xs) {
                        chipBadge(d.subtype.displayName, tint: .accentColor)
                        chipBadge(d.class.displayName, tint: .secondary)
                        if d.state.archived {
                            chipBadge("Archivado", tint: .orange)
                        } else {
                            chipBadge(d.state.status.capitalized, tint: .green)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            if let value = d.metrics.estimatedValue, let currency = d.metrics.currency {
                HStack {
                    Image(systemName: "banknote")
                        .foregroundStyle(.secondary)
                    Text(formatCurrency(value, currency: currency))
                        .font(.headline)
                    Spacer()
                }
                .padding(.top, Theme.Spacing.xs)
            }
            if !d.effectiveCapabilities.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.xs) {
                        ForEach(d.effectiveCapabilities, id: \.self) { cap in
                            chipBadge(cap.replacingOccurrences(of: "_", with: " "), tint: .blue)
                        }
                    }
                }
            }
        }
        .padding(Theme.Spacing.xl)
        .background(Theme.Surface.card, in: Theme.cardShape(Theme.Radius.cardHero))
    }

    // MARK: - Widgets row

    @ViewBuilder
    private func widgetsRow(_ widgets: [ResourceWidget]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Dashboard")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.md) {
                    ForEach(widgets) { widget in
                        widgetCard(widget)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func widgetCard(_ widget: ResourceWidget) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Image(systemName: widget.icon ?? "rectangle.stack")
                .font(.system(size: Theme.IconSize.md, weight: .regular))
                .foregroundStyle(Color.accentColor)
            Text(widget.displayName)
                .font(.subheadline.bold())
            if let src = widget.dataSourceKey {
                Text(src)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(width: 140, alignment: .leading)
        .padding(Theme.Spacing.md)
        .background(Theme.Surface.card, in: Theme.cardShape())
    }

    // MARK: - Sections

    @ViewBuilder
    private func sectionsCard(_ d: ResourceDetailDescriptor) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Secciones")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(d.sections.enumerated().map { ($0, $1) }, id: \.1.id) { idx, section in
                    sectionLink(d, section: section)
                    if idx < d.sections.count - 1 { Divider().padding(.leading, 56) }
                }
            }
            .background(Theme.Surface.card, in: Theme.cardShape())
        }
    }

    /// Si la section tiene destino, envuelve en NavigationLink; si no, row plana.
    @ViewBuilder
    private func sectionLink(_ d: ResourceDetailDescriptor, section: ResourceSection) -> some View {
        if let _ = sectionDestinationKey(section.sectionKey) {
            NavigationLink {
                sectionDestination(d, sectionKey: section.sectionKey)
            } label: {
                sectionRow(section, tappable: true)
            }
            .buttonStyle(.plain)
        } else {
            sectionRow(section, tappable: false)
        }
    }

    /// Sentinel para saber si una section_key tiene destino wireado.
    private func sectionDestinationKey(_ key: String) -> String? {
        switch key {
        case "reservations", "availability", "activity", "settings": return key
        default: return nil
        }
    }

    /// Destinos legacy por section_key. Reservations usa ReservationsListView
    /// scoped a este resource; settings abre ResourceSettingsView.
    @ViewBuilder
    private func sectionDestination(_ d: ResourceDetailDescriptor, sectionKey: String) -> some View {
        switch sectionKey {
        case "reservations", "availability":
            ReservationsListView(
                resource: d.resource,
                context: context,
                reservationContextId: nil,
                container: container
            )
        case "activity":
            ActivityFeedView(context: context, container: container)
        case "settings":
            ResourceSettingsView(resourceId: resourceId, container: container)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func sectionRow(_ section: ResourceSection, tappable: Bool) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            Image(systemName: section.icon ?? "circle")
                .foregroundStyle(Color.accentColor)
                .frame(width: Theme.IconSize.sm, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(section.displayName)
                    .font(.body)
                    .foregroundStyle(.primary)
                if let cap = section.requiredCapability {
                    Text("Requiere: \(cap)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if tappable {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.md)
        .contentShape(Rectangle())
    }

    // MARK: - Actions

    @ViewBuilder
    private func actionsCard(_ d: ResourceDetailDescriptor) -> some View {
        let bySection = Dictionary(grouping: d.actions) { $0.section }
        let sectionOrder = bySection.keys.sorted()
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("Acciones disponibles")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            ForEach(sectionOrder, id: \.self) { sectionKey in
                if let actions = bySection[sectionKey] {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(sectionKey.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.caption.bold())
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)
                        VStack(spacing: 0) {
                            ForEach(actions.enumerated().map { ($0, $1) }, id: \.1.id) { idx, action in
                                Button {
                                    guard action.enabled else { return }
                                    pendingAction = PendingAction(action: action, form: descriptorForm(for: action))
                                } label: {
                                    actionRow(action)
                                }
                                .buttonStyle(.plain)
                                .disabled(!action.enabled)
                                if idx < actions.count - 1 { Divider().padding(.leading, 56) }
                            }
                        }
                        .background(Theme.Surface.card, in: Theme.cardShape())
                    }
                }
            }
        }
    }

    /// Lookup del form correspondiente en `descriptor.action_forms`.
    private func descriptorForm(for action: ResourceDescriptorAction) -> ResourceActionForm? {
        store.descriptor?.form(for: action.actionKey)
    }

    @ViewBuilder
    private func actionRow(_ action: ResourceDescriptorAction) -> some View {
        let presentation = ActionPresentationCatalog.presentation(for: action.actionKey)
        let tint = action.dangerous ? Color.red : presentation.tint
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: presentation.symbolName)
                .foregroundStyle(action.enabled ? tint : .secondary)
                .frame(width: Theme.IconSize.sm, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(action.label)
                        .foregroundStyle(action.enabled ? .primary : .secondary)
                    if action.isRequestDecision {
                        Text("·  vía decisión")
                            .font(.caption2)
                            .foregroundStyle(.purple)
                    }
                    if action.dangerous {
                        Text("·  peligroso")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                if !action.enabled, let reason = action.reason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if action.formSchemaPresent {
                Image(systemName: "list.bullet.rectangle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.md)
        .contentShape(Rectangle())
    }

    // MARK: - Relations

    @ViewBuilder
    private func relationsCard(_ relations: ResourceRelationsBundle) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Relaciones")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                let all = relations.outbound + relations.inbound
                ForEach(all.enumerated().map { ($0, $1) }, id: \.1.id) { idx, rel in
                    relationRow(rel)
                    if idx < all.count - 1 { Divider().padding(.leading, 56) }
                }
            }
            .background(Theme.Surface.card, in: Theme.cardShape())
        }
    }

    @ViewBuilder
    private func relationRow(_ rel: ResourceRelation) -> some View {
        NavigationLink {
            ResourceDetailViewV2(resourceId: rel.otherResourceId, context: context, container: container)
        } label: {
            HStack(alignment: .center, spacing: Theme.Spacing.md) {
                Image(systemName: rel.isOutbound ? "arrow.right" : "arrow.left")
                    .foregroundStyle(.secondary)
                    .frame(width: Theme.IconSize.sm, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rel.other.displayName)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(rel.relationType.replacingOccurrences(of: "_", with: " "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let subKey = rel.other.subtypeKey {
                    Text(subKey.replacingOccurrences(of: "_", with: " "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Activity preview

    @ViewBuilder
    private func activityCard(_ events: [ActivityPreviewEvent]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text("Actividad reciente").font(.subheadline.bold()).foregroundStyle(.secondary)
                Spacer()
                NavigationLink {
                    ActivityFeedView(context: context, container: container)
                } label: {
                    Text("Ver todo").font(.caption).foregroundStyle(Color.accentColor)
                }
            }
            VStack(spacing: 0) {
                ForEach(events.prefix(5).enumerated().map { ($0, $1) }, id: \.1.id) { idx, ev in
                    activityRow(ev)
                    if idx < min(events.count, 5) - 1 { Divider().padding(.leading, 56) }
                }
            }
            .background(Theme.Surface.card, in: Theme.cardShape())
        }
    }

    @ViewBuilder
    private func activityRow(_ ev: ActivityPreviewEvent) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: "bolt.circle")
                .foregroundStyle(.secondary)
                .frame(width: Theme.IconSize.sm, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(ev.eventType.replacingOccurrences(of: ".", with: " · "))
                    .font(.subheadline)
                if let when = ev.occurredAt {
                    Text(when.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.md)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func chipBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(tint.badgeFillSubtle, in: Capsule())
    }

    private func formatCurrency(_ value: Double, currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: value)) ?? "\(value) \(currency)"
    }
}
