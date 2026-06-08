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
    /// algún flow (edit/settings).
    @State private var isShowingClassicSheet = false
    /// R.5A wire P1.4 — sheets nativos para grant_right + attach_document
    /// (los dos action_keys más usados en v1).
    @State private var documentsStore: DocumentsStore
    @State private var isShowingGrantRight = false
    @State private var isShowingAttachDocument = false
    @State private var isShowingEditResource = false
    /// P3 — chip seleccionada para alert explicativo.
    @State private var explainedCapability: String?
    /// R.5B.5b — conflict pendiente para confirmation dialog (3 kinds).
    @State private var pendingConflict: ResourceConflict?
    @State private var isShowingConflictDialog = false
    /// R.5B.5b — alert post-resolve (éxito/error).
    @State private var conflictResolveAlert: ConflictResolveAlert?
    @State private var isShowingConflictAlert = false
    /// R.5B.5b — bloquea taps adicionales mientras se resuelve.
    @State private var isResolvingConflict = false

    public init(resourceId: UUID, context: AppContext, container: DependencyContainer) {
        self.resourceId = resourceId
        self.context = context
        self.container = container
        _store = State(initialValue: ResourceDescriptorStore(rpc: container.rpc))
        _documentsStore = State(initialValue: DocumentsStore(rpc: container.rpc))
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
                context: context,
                container: container
            ) { _ in
                Task { await store.refreshActions(resourceId: resourceId) }
            }
        }
        // P1.4 — sheets nativos (los más usados en v1, NO via form runtime)
        .sheet(isPresented: $isShowingGrantRight) {
            if let d = store.descriptor {
                GrantRightSheet(resource: d.resource, context: context, container: container) {
                    Task { await store.load(resourceId: resourceId) }
                }
            }
        }
        .sheet(isPresented: $isShowingAttachDocument) {
            if let d = store.descriptor {
                AttachDocumentView(
                    resource: d.resource,
                    context: context,
                    container: container,
                    store: documentsStore
                )
            }
        }
        .sheet(isPresented: $isShowingEditResource) {
            if let d = store.descriptor {
                EditResourceView(resource: d.resource, container: container) {
                    Task { await store.load(resourceId: resourceId) }
                }
            }
        }
        .alert(
            explainedCapability.map { capabilityDisplayName($0) } ?? "",
            isPresented: Binding(
                get: { explainedCapability != nil },
                set: { if !$0 { explainedCapability = nil } }
            ),
            presenting: explainedCapability
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { cap in
            Text(capabilityDescription(cap))
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
        // R.5B.5b — modifiers de conflictos en un chain separado para evitar
        // type-checker timeout del body principal.
        .modifier(ConflictsModifier(
            pendingConflict: $pendingConflict,
            isShowingDialog: $isShowingConflictDialog,
            alert: $conflictResolveAlert,
            isShowingAlert: $isShowingConflictAlert,
            dialogMessage: conflictDialogMessage(_:),
            onKind: { conflict, kind in resolveConflict(conflict, kind: kind) }
        ))
    }

    // MARK: - Scroll body

    @ViewBuilder
    private func descriptorScroll(_ d: ResourceDetailDescriptor) -> some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                heroCard(d)
                if d.conflicts.openCount > 0 { conflictsCard(d.conflicts) }
                if !d.widgets.isEmpty { widgetsRow(d.widgets, descriptor: d) }
                if !d.sections.isEmpty { sectionsCard(d) }
                if !d.actions.isEmpty { actionsCard(d) }
                if !d.relations.outbound.isEmpty || !d.relations.inbound.isEmpty {
                    relationsCard(d.relations)
                }
                linkedEventsCard(d.linkedEvents)
                linkedObligationsCard(d.linkedObligations)
                linkedDecisionsCard(d.linkedDecisions)
                // Documents V2 D.5 — antes era dead struct (descriptor.linkedDocuments
                // decoded but never rendered). Card hace su propio fetch para tener
                // Documents completos con storage_path para tap → DocumentDetailView.
                ResourceLinkedDocumentsCard(resourceId: resourceId, context: context, container: container)
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
                            Button {
                                explainedCapability = cap
                            } label: {
                                chipBadge(capabilityDisplayName(cap), tint: .blue)
                            }
                            .buttonStyle(.plain)
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
    private func widgetsRow(_ widgets: [ResourceWidget], descriptor: ResourceDetailDescriptor) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Dashboard")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.md) {
                    ForEach(widgets) { widget in
                        widgetCard(widget, descriptor: descriptor)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func widgetCard(_ widget: ResourceWidget, descriptor: ResourceDetailDescriptor) -> some View {
        if let _ = resourceWidgetDestinationKey(widget.widgetKey) {
            NavigationLink {
                resourceWidgetDestination(widgetKey: widget.widgetKey, descriptor: descriptor)
            } label: {
                widgetCardBody(widget, tappable: true)
            }
            .buttonStyle(.plain)
        } else {
            widgetCardBody(widget, tappable: false)
        }
    }

    @ViewBuilder
    private func widgetCardBody(_ widget: ResourceWidget, tappable: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .top) {
                Image(systemName: widget.icon ?? "rectangle.stack")
                    .font(.system(size: Theme.IconSize.md, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                Spacer()
                if tappable {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Text(widget.displayName)
                .font(.subheadline.bold())
                .foregroundStyle(.primary)
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
        .contentShape(Rectangle())
    }

    /// Sentinel para widgets con destino legacy wireado.
    private func resourceWidgetDestinationKey(_ key: String) -> String? {
        switch key {
        case "balance_summary", "member_balance_summary", "income_summary",
             "lease_status", "open_obligations":
            return "money"
        case "next_event":
            return "events"
        case "recent_activity":
            return "activity"
        case "reservation_status", "upcoming_reservations":
            return "reservations"
        case "settlement_status":
            return "settlement"
        default:
            return nil
        }
    }

    @ViewBuilder
    private func resourceWidgetDestination(widgetKey: String, descriptor: ResourceDetailDescriptor) -> some View {
        switch resourceWidgetDestinationKey(widgetKey) {
        case "money":
            MoneyHomeView(context: context, container: container)
        case "events":
            EventsListView(context: context, container: container)
        case "activity":
            ActivityFeedView(context: context, container: container)
        case "reservations":
            ReservationsListView(
                resource: descriptor.resource,
                context: context,
                reservationContextId: nil,
                container: container
            )
        case "settlement":
            SettlementView(context: context, container: container)
        default:
            EmptyView()
        }
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
                                    handleActionTap(action)
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

    /// P1.4/P3 — algunos action_keys tienen sheet nativo dedicado (mejor UX
    /// que el form runtime genérico). Resto cae a ResourceActionFormView.
    private func handleActionTap(_ action: ResourceDescriptorAction) {
        switch action.actionKey {
        case "grant_right":
            isShowingGrantRight = true
        case "attach_document":
            isShowingAttachDocument = true
        case "edit_resource", "update_resource":
            isShowingEditResource = true
        default:
            pendingAction = PendingAction(action: action, form: descriptorForm(for: action))
        }
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

    // MARK: - Linked entities (B.6.1)

    @ViewBuilder
    private func linkedEventsCard(_ raw: [JSONValue]) -> some View {
        let items = parseLinkedEvents(raw)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Eventos relacionados")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(items.enumerated().map { ($0, $1) }, id: \.1.id) { idx, ev in
                        NavigationLink {
                            EventDetailView(eventId: ev.id, context: context, container: container)
                        } label: {
                            HStack(spacing: Theme.Spacing.md) {
                                Image(systemName: "calendar")
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: Theme.IconSize.sm)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ev.title).font(.body).foregroundStyle(.primary).lineLimit(1)
                                    if let when = ev.startsAt {
                                        Text(when.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption).foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer()
                                if let status = ev.status {
                                    Text(status).font(.caption2).foregroundStyle(.tertiary)
                                }
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.md)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if idx < items.count - 1 { Divider().padding(.leading, 56) }
                    }
                }
                .background(Theme.Surface.card, in: Theme.cardShape())
            }
        }
    }

    @ViewBuilder
    private func linkedObligationsCard(_ raw: [JSONValue]) -> some View {
        let items = parseLinkedObligations(raw)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Obligaciones relacionadas")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(items.enumerated().map { ($0, $1) }, id: \.1.id) { idx, o in
                        NavigationLink {
                            ObligationDetailView(obligationId: o.id, context: context, container: container)
                        } label: {
                            HStack(spacing: Theme.Spacing.md) {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(.secondary)
                                    .frame(width: Theme.IconSize.sm)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(o.title ?? o.kind ?? "Obligación").font(.body).foregroundStyle(.primary).lineLimit(1)
                                    if let status = o.status {
                                        Text(status).font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer()
                                if let amount = o.amount, let cur = o.currency {
                                    Text("\(Int(amount)) \(cur)").font(.subheadline.bold()).foregroundStyle(.primary)
                                }
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.md)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if idx < items.count - 1 { Divider().padding(.leading, 56) }
                    }
                }
                .background(Theme.Surface.card, in: Theme.cardShape())
            }
        }
    }

    @ViewBuilder
    private func linkedDecisionsCard(_ raw: [JSONValue]) -> some View {
        let items = parseLinkedDecisions(raw)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Decisiones relacionadas")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(items.enumerated().map { ($0, $1) }, id: \.1.id) { idx, dx in
                        NavigationLink {
                            DecisionDetailView(decisionId: dx.id, context: context, container: container)
                        } label: {
                            HStack(spacing: Theme.Spacing.md) {
                                Image(systemName: "questionmark.circle")
                                    .foregroundStyle(.purple)
                                    .frame(width: Theme.IconSize.sm)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(dx.title).font(.body).foregroundStyle(.primary).lineLimit(1)
                                    HStack(spacing: 4) {
                                        if let tmpl = dx.templateKey {
                                            Text(tmpl).font(.caption2).foregroundStyle(.tertiary)
                                        }
                                        if let st = dx.status {
                                            Text("· \(st)").font(.caption2).foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.md)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if idx < items.count - 1 { Divider().padding(.leading, 56) }
                    }
                }
                .background(Theme.Surface.card, in: Theme.cardShape())
            }
        }
    }

    // MARK: - JSONValue parsers (B.6.1 shapes son [JSONValue] opacos en Domain)

    private struct LinkedEventItem: Identifiable {
        let id: UUID
        let title: String
        let startsAt: Date?
        let status: String?
    }

    private struct LinkedObligationItem: Identifiable {
        let id: UUID
        let title: String?
        let kind: String?
        let status: String?
        let amount: Double?
        let currency: String?
    }

    private struct LinkedDecisionItem: Identifiable {
        let id: UUID
        let title: String
        let status: String?
        let templateKey: String?
    }

    private func parseLinkedEvents(_ raw: [JSONValue]) -> [LinkedEventItem] {
        raw.compactMap { v in
            guard case .object(let o) = v,
                  case .string(let idStr)? = o["event_id"], let id = UUID(uuidString: idStr),
                  case .string(let title)? = o["title"]
            else { return nil }
            var startsAt: Date?
            if case .string(let s)? = o["starts_at"] {
                startsAt = ISO8601DateFormatter().date(from: s)
            }
            var status: String?
            if case .string(let s)? = o["status"] { status = s }
            return LinkedEventItem(id: id, title: title, startsAt: startsAt, status: status)
        }
    }

    private func parseLinkedObligations(_ raw: [JSONValue]) -> [LinkedObligationItem] {
        raw.compactMap { v in
            guard case .object(let o) = v,
                  case .string(let idStr)? = o["obligation_id"], let id = UUID(uuidString: idStr)
            else { return nil }
            var title: String?
            if case .string(let s)? = o["title"] { title = s }
            var kind: String?
            if case .string(let s)? = o["obligation_kind"] { kind = s }
            else if case .string(let s)? = o["obligation_type"] { kind = s }
            var status: String?
            if case .string(let s)? = o["status"] { status = s }
            var amount: Double?
            if case .number(let n)? = o["amount"] { amount = n }
            var currency: String?
            if case .string(let s)? = o["currency"] { currency = s }
            return LinkedObligationItem(id: id, title: title, kind: kind, status: status, amount: amount, currency: currency)
        }
    }

    private func parseLinkedDecisions(_ raw: [JSONValue]) -> [LinkedDecisionItem] {
        raw.compactMap { v in
            guard case .object(let o) = v,
                  case .string(let idStr)? = o["decision_id"], let id = UUID(uuidString: idStr),
                  case .string(let title)? = o["title"]
            else { return nil }
            var status: String?
            if case .string(let s)? = o["status"] { status = s }
            var tmpl: String?
            if case .string(let s)? = o["template_key"] { tmpl = s }
            return LinkedDecisionItem(id: id, title: title, status: status, templateKey: tmpl)
        }
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

    // MARK: - Capability catalog (snapshot estático de resource_capabilities_catalog)

    private static let capabilityCatalog: [String: (displayName: String, description: String)] = [
        "access_controlled":     ("Acceso controlado", "Tiene control de acceso físico o digital."),
        "approvable":            ("Aprobable", "Sus cambios pueden someterse a aprobación explícita."),
        "approval_required":     ("Requiere aprobación", "Sus cambios requieren aprobación."),
        "assignable":            ("Asignable", "Puede asignarse a un actor (custodio, holder)."),
        "auditable":             ("Auditable", "Sus movimientos quedan auditados."),
        "beneficiary_supported": ("Con beneficiarios", "Puede tener beneficiarios designados."),
        "chargeable":            ("Cobrable", "Puede emitir cargos / cobros."),
        "closeable":             ("Cerrable", "Puede cerrarse / finalizarse."),
        "condition_trackable":   ("Condición rastreable", "Su condición física/estado puede registrarse."),
        "custodiable":           ("Custodiable", "Puede tener custodio asignado."),
        "depreciable":           ("Depreciable", "Pierde valor en el tiempo."),
        "disputable":            ("Disputable", "Puede disputarse / impugnarse."),
        "documentable":          ("Documentable", "Puede tener documentos asociados."),
        "expirable":             ("Expirable", "Tiene fecha de expiración."),
        "governable":            ("Gobernable", "Puede someterse a decisiones del contexto."),
        "income_generating":     ("Genera ingreso", "Genera flujo de ingreso (renta, dividendos)."),
        "insurable":             ("Asegurable", "Puede tener seguro asociado."),
        "inventory_tracked":     ("Inventariable", "Forma parte de un inventario stock-tracked."),
        "leasable":              ("Arrendable", "Puede arrendarse a terceros."),
        "location_bound":        ("Ligado a ubicación", "Tiene ubicación física relevante."),
        "maintainable":          ("Mantenible", "Puede registrar mantenimiento / servicio."),
        "monetary":              ("Monetario", "Puede registrar y mover dinero."),
        "notifiable":            ("Notificable", "Emite notificaciones por su lifecycle."),
        "ownable":               ("Apropiable", "Puede tener owners formales (rights OWN)."),
        "ownership_trackable":   ("Propiedad rastreable", "Su propiedad (OWN %) se rastrea por porcentajes."),
        "payable":               ("Pagable", "Puede recibir pagos / cargos monetarios."),
        "quantity_tracked":      ("Cantidad rastreable", "Tiene cantidad numérica rastreada."),
        "recurring":             ("Recurrente", "Se repite en patrón temporal."),
        "rentable":              ("Rentable", "Puede rentarse a terceros."),
        "reservable":            ("Reservable", "Puede reservarse en bloques de tiempo."),
        "rule_bound":            ("Sujeto a reglas", "Su comportamiento se ve afectado por rules."),
        "schedulable":           ("Calendarizable", "Puede agendarse en el tiempo."),
        "sellable":              ("Vendible", "Puede venderse."),
        "settleable":            ("Liquidable", "Puede liquidarse en settlement batches."),
        "shareable":             ("Compartible", "Puede compartirse con varios actores vía rights."),
        "signable":              ("Firmable", "Puede firmarse digitalmente."),
        "splittable":            ("Divisible", "Sus montos pueden dividirse entre actores."),
        "taxable":               ("Sujeto a impuestos", "Genera obligaciones fiscales."),
        "transferable":          ("Transferible", "Puede transferirse a otro actor."),
        "usable":                ("Usable", "Puede usarse sin reserva formal (right USE)."),
        "versionable":           ("Versionable", "Tiene versiones rastreables."),
        "votable":               ("Votable", "Puede someterse a votación.")
    ]

    private func capabilityDisplayName(_ key: String) -> String {
        Self.capabilityCatalog[key]?.displayName
            ?? key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func capabilityDescription(_ key: String) -> String {
        Self.capabilityCatalog[key]?.description
            ?? "Capacidad del recurso \"\(key)\"."
    }

    // MARK: - R.5B.5b — Conflicts card

    @ViewBuilder
    private func conflictsCard(_ list: ResourceConflictList) -> some View {
        let critical = list.items.filter(\.isCritical).count
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .center, spacing: Theme.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: Theme.IconSize.md, weight: .regular))
                    .foregroundStyle(critical > 0 ? Color.red : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Conflictos abiertos")
                        .font(.subheadline.bold())
                    Text(conflictsSubtitle(open: list.openCount, critical: critical))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("\(list.openCount)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(critical > 0 ? Color.red : Color.orange)
            }
            VStack(spacing: Theme.Spacing.xs) {
                ForEach(list.items.prefix(4)) { item in
                    Button {
                        guard !isResolvingConflict else { return }
                        pendingConflict = item
                        isShowingConflictDialog = true
                    } label: {
                        conflictRow(item)
                    }
                    .buttonStyle(.plain)
                    .disabled(isResolvingConflict)
                }
            }
            if list.items.count > 4 {
                Text("+ \(list.items.count - 4) más")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.Surface.card, in: Theme.cardShape(Theme.Radius.card))
        .overlay(
            Theme.cardShape(Theme.Radius.card)
                .stroke((critical > 0 ? Color.red : Color.orange).opacity(0.25), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func conflictRow(_ c: ResourceConflict) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.sm) {
            Image(systemName: conflictSeverityIcon(c.severity))
                .font(.system(size: Theme.IconSize.sm, weight: .regular))
                .foregroundStyle(conflictSeverityTint(c.severity))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.conflictTypeDisplay ?? c.conflictType)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(conflictRowSubtitle(c))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .padding(.horizontal, Theme.Spacing.sm)
        .background(conflictSeverityTint(c.severity).badgeFillSubtle, in: Theme.cardShape())
        .contentShape(Rectangle())
    }

    private func conflictsSubtitle(open: Int, critical: Int) -> String {
        if critical > 0 {
            return critical == open
                ? "\(critical) crítico\(critical == 1 ? "" : "s")"
                : "\(critical) crítico\(critical == 1 ? "" : "s") · \(open) abierto\(open == 1 ? "" : "s")"
        }
        return "\(open) abierto\(open == 1 ? "" : "s")"
    }

    private func conflictRowSubtitle(_ c: ResourceConflict) -> String {
        if c.sourceDecisionId != nil {
            return "Escalado a decisión"
        }
        switch c.sourceType {
        case "reservation_conflict", "reservation_pair":
            return c.category?.capitalized ?? "Conflicto de reservación"
        case "reservation":
            return "Reserva afectada"
        default:
            return c.category?.capitalized ?? c.severity.capitalized
        }
    }

    private func conflictSeverityIcon(_ severity: String) -> String {
        switch severity {
        case "critical": return "exclamationmark.octagon.fill"
        case "warning":  return "exclamationmark.triangle.fill"
        case "info":     return "info.circle.fill"
        default:         return "exclamationmark.circle"
        }
    }

    private func conflictSeverityTint(_ severity: String) -> Color {
        switch severity {
        case "critical": return Color.red
        case "warning":  return Color.orange
        case "info":     return Color.blue
        default:         return Color.secondary
        }
    }

    private func conflictDialogMessage(_ c: ResourceConflict) -> String {
        let action = c.recommendedActionKey ?? "resolve_resource_conflict"
        let recommended: String
        switch action {
        case "escalate_to_decision":
            recommended = "Recomendado: escalar a decisión."
        case "resolve_reservation_conflict", "resolve_resource_conflict":
            recommended = "Recomendado: resolver manualmente."
        default:
            recommended = ""
        }
        return ["¿Qué hacemos con este conflicto?", recommended]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private func resolveConflict(_ c: ResourceConflict, kind: ResolveResourceConflictKind) {
        guard !isResolvingConflict else { return }
        isResolvingConflict = true
        Task { @MainActor in
            defer { isResolvingConflict = false }
            do {
                let result = try await container.rpc.resolveResourceConflict(
                    conflictId: c.conflictId,
                    kind: kind,
                    winnerActorId: nil,
                    payload: .object([:])
                )
                await store.refreshConflicts(resourceId: resourceId)
                if result.noOp {
                    conflictResolveAlert = ConflictResolveAlert(
                        title: "Sin cambios",
                        message: "El conflicto ya no estaba abierto."
                    )
                } else {
                    conflictResolveAlert = ConflictResolveAlert(
                        title: resolveSuccessTitle(kind),
                        message: resolveSuccessMessage(kind, result: result)
                    )
                }
                isShowingConflictAlert = true
            } catch {
                conflictResolveAlert = ConflictResolveAlert(
                    title: "No pudimos resolver",
                    message: UserFacingError.from(error).message
                )
                isShowingConflictAlert = true
            }
        }
    }

    private func resolveSuccessTitle(_ kind: ResolveResourceConflictKind) -> String {
        switch kind {
        case .manualResolution: return "Resuelto"
        case .escalate:         return "Escalado"
        case .dismiss:          return "Descartado"
        }
    }

    private func resolveSuccessMessage(_ kind: ResolveResourceConflictKind, result: ResolveResourceConflictResult) -> String {
        switch kind {
        case .manualResolution:
            return "El conflicto quedó resuelto."
        case .escalate:
            if let tmpl = result.templateKey {
                return "Se creó una decisión (\(tmpl)) para resolver el conflicto."
            }
            return "Se creó una decisión para resolver el conflicto."
        case .dismiss:
            return "El conflicto fue descartado."
        }
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

// MARK: - R.5B.5b — ConflictsModifier
//
// Aísla el confirmation dialog + alert de conflictos en un chain separado
// para evitar que el type-checker del body principal explote (gotcha cazado
// al sumar al 8º modifier del body).

private struct ConflictsModifier: ViewModifier {
    @Binding var pendingConflict: ResourceConflict?
    @Binding var isShowingDialog: Bool
    @Binding var alert: ConflictResolveAlert?
    @Binding var isShowingAlert: Bool
    let dialogMessage: (ResourceConflict) -> String
    let onKind: (ResourceConflict, ResolveResourceConflictKind) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                pendingConflict?.conflictTypeDisplay ?? "Conflicto",
                isPresented: $isShowingDialog,
                titleVisibility: .visible,
                presenting: pendingConflict
            ) { conflict in
                Button("Resolver manualmente") { onKind(conflict, .manualResolution) }
                Button("Escalar a decisión")  { onKind(conflict, .escalate) }
                Button("Descartar", role: .destructive) { onKind(conflict, .dismiss) }
                Button("Cancelar", role: .cancel) {}
            } message: { conflict in
                Text(dialogMessage(conflict))
            }
            .alert(
                alert?.title ?? "",
                isPresented: $isShowingAlert,
                presenting: alert
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { a in
                Text(a.message)
            }
    }
}

/// R.5B.5b — alert post-resolve. Fileprivate para ser accesible desde
/// ConflictsModifier sin exponerlo al resto del app.
fileprivate struct ConflictResolveAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
