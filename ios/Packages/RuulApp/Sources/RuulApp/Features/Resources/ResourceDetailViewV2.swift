import SwiftUI
import RuulCore

/// R.5A.F.1 + R.5V.5 — Resource Detail backed by `resource_detail_descriptor`.
///
/// **R.5V.5 (2026-06-07):** refactor visual a `List + Section` Apple-native.
/// Doctrina canónica DocumentDetailView (founder firmada 2026-06-07): la
/// Section ES la card. Cero VStack envueltos en `Theme.cardShape()`.
///
/// Estructura:
/// ```
/// List(.insetGrouped) {
///   Section { heroRow + capabilities chips }   // .listRowSeparator(.hidden)
///   Section "Conflictos abiertos" (conditional)
///   Section "Información"                       // LabeledContent
///   Section "Dashboard"                         // widgets carousel
///   Section "Secciones"                         // NavigationLinks descriptor.sections
///   Section "Acciones · <group>" (multiple)     // Button + Label nativo · dangerous = role .destructive
///   Section "Relaciones" (conditional)
///   Section "Eventos relacionados" (conditional)
///   Section "Obligaciones relacionadas" (conditional)
///   Section "Decisiones relacionadas" (conditional)
///   Section "Documentos" (conditional)
///   Section "Actividad reciente" (conditional)
/// }
/// ```
///
/// Lógica preservada: descriptor store, conflicts dialog modifier, capability
/// alert, native sheets (grant_right / attach_document / edit_resource),
/// classic fallback sheet, action dispatcher (handleActionTap), all parsers.
/// Removido: ResourceLinkedDocumentsCard separado (inline ahora con documentsStore).
public struct ResourceDetailViewV2: View {
    let resourceId: UUID
    let context: AppContext
    let container: DependencyContainer

    @State private var store: ResourceDescriptorStore
    @State private var pendingAction: PendingAction?
    @State private var isShowingClassicSheet = false
    @State private var documentsStore: DocumentsStore
    @State private var isShowingGrantRight = false
    @State private var isShowingAttachDocument = false
    @State private var isShowingEditResource = false
    @State private var explainedCapability: String?
    @State private var pendingConflict: ResourceConflict?
    @State private var isShowingConflictDialog = false
    @State private var conflictResolveAlert: ConflictResolveAlert?
    @State private var isShowingConflictAlert = false
    @State private var isResolvingConflict = false
    @State private var pushedDocumentId: UUID?
    @State private var isShowingAllDocuments = false
    /// R.7.x — flow para `resource.transfer`. Catalog default es
    /// `requires_decision=true`, así que UI va siempre por governance.
    @State private var runner = ActionRunner()
    @State private var isShowingTransferPicker = false
    @State private var contextMembersForTransfer: [ContextMember] = []
    @State private var transferRecipientId: UUID?
    @State private var isShowingTransferGovernanceSheet = false
    @State private var transferClientId: String = UUID().uuidString
    @State private var pendingTransferDecisionId: UUID?

    public init(resourceId: UUID, context: AppContext, container: DependencyContainer) {
        self.resourceId = resourceId
        self.context = context
        self.container = container
        _store = State(initialValue: ResourceDescriptorStore(rpc: container.rpc))
        _documentsStore = State(initialValue: DocumentsStore(rpc: container.rpc))
    }

    private struct PendingAction: Identifiable {
        let action: ResourceDescriptorAction
        let form: ResourceActionForm?
        var id: String { action.actionKey }
    }

    public var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                RuulLoadingState()
            case .failed(let message):
                RuulErrorState(message: message) {
                    Task { await store.load(resourceId: resourceId) }
                }
            case .loaded:
                if let descriptor = store.descriptor {
                    descriptorList(descriptor)
                }
            }
        }
        .navigationTitle(store.descriptor?.resource.displayName ?? "Recurso")
        .navigationBarTitleDisplayMode(.inline)
        // P0 fix 2026-06-08 — toolbar específico del recurso:
        //   - Trailing "+": Menu con descriptor.actions enabled (acciones rápidas
        //     más comunes — attach_document / grant_right / edit_resource / etc.).
        //   - Trailing "ellipsis": Menu con drill-downs específicos del recurso
        //     (Configuración, Vista clásica) en vez de solo legacy "Vista clásica".
        .toolbar {
            if let descriptor = store.descriptor, !descriptor.actions.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    resourceQuickActionsMenu(actions: descriptor.actions, descriptor: descriptor)
                }
                // R.5V.Toolbar.Spacers — separa "+" (quick actions) del
                // "ellipsis" (más opciones) en cápsulas Liquid Glass distintas.
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("Explorar") {
                        Button {
                            isShowingEditResource = true
                        } label: {
                            Label("Editar recurso", systemImage: "pencil")
                        }
                    }
                    // R.7.x — surface governance-routed transfer.
                    if !context.isPersonal, store.descriptor?.state.archived == false {
                        Section("Gestión") {
                            Button {
                                Task { await openTransferPicker() }
                            } label: {
                                Label("Transferir propiedad", systemImage: "arrow.left.arrow.right")
                            }
                        }
                    }
                    Section("Avanzado") {
                        Button {
                            isShowingClassicSheet = true
                        } label: {
                            Label("Vista clásica", systemImage: "rectangle.stack")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Más opciones del recurso")
            }
        }
        .task {
            await store.load(resourceId: resourceId)
            await documentsStore.loadResourceDocuments(resourceId: resourceId)
        }
        .refreshable {
            await store.load(resourceId: resourceId)
            await documentsStore.loadResourceDocuments(resourceId: resourceId)
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
        .sheet(isPresented: $isShowingAllDocuments) {
            NavigationStack {
                ContextDocumentsListView(context: context, container: container)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cerrar") { isShowingAllDocuments = false }
                        }
                    }
            }
        }
        .navigationDestination(item: $pushedDocumentId) { id in
            if let doc = documentsStore.documents.first(where: { $0.id == id }) {
                DocumentDetailView(document: doc, context: context, container: container, store: documentsStore)
            } else {
                RuulErrorState(message: "Documento no encontrado.")
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
        .modifier(ConflictsModifier(
            pendingConflict: $pendingConflict,
            isShowingDialog: $isShowingConflictDialog,
            alert: $conflictResolveAlert,
            isShowingAlert: $isShowingConflictAlert,
            dialogMessage: conflictDialogMessage(_:),
            onKind: { conflict, kind in resolveConflict(conflict, kind: kind) }
        ))
        .modifier(TransferFlowModifier(
            isShowingPicker: $isShowingTransferPicker,
            members: $contextMembersForTransfer,
            recipientId: $transferRecipientId,
            isShowingGovernanceSheet: $isShowingTransferGovernanceSheet,
            pendingDecisionId: $pendingTransferDecisionId,
            resource: store.descriptor?.resource,
            context: context,
            container: container,
            governanceMessage: transferGovernanceMessage,
            onConfirmRecipient: { isShowingTransferGovernanceSheet = true },
            onRequestGovernance: { Task { await requestGovernanceTransfer() } }
        ))
        .actionErrorAlert(runner)
    }

    // MARK: - R.7.x transfer

    /// Carga miembros activos del contexto y abre el picker. Excluye al caller
    /// (no se puede transferir a uno mismo) y a actors archivados.
    private func openTransferPicker() async {
        guard let descriptor = store.descriptor else { return }
        do {
            let summary = try await container.rpc.contextSummary(contextId: context.id)
            let canonicalOwner = descriptor.resource.canonicalOwnerActorId
            contextMembersForTransfer = summary.members.filter { member in
                member.actorId != canonicalOwner
            }
            transferRecipientId = nil
            transferClientId = UUID().uuidString
            isShowingTransferPicker = true
        } catch {
            // fail-silent: el alert global runner no aplica aquí (no fue una RPC write).
            contextMembersForTransfer = []
        }
    }

    /// Pide aprobación colectiva para `resource.transfer` con `payload={to_actor_id}`.
    private func requestGovernanceTransfer() async {
        guard let recipientId = transferRecipientId else { return }
        let input = RequestGovernanceActionInput(
            contextActorId: context.id,
            actionKey: "resource.transfer",
            targetType: "resource",
            targetId: resourceId,
            payload: .object([
                "to_actor_id": .string(recipientId.uuidString)
            ]),
            title: transferDecisionTitle(recipientId: recipientId),
            closesAt: nil,
            clientId: transferClientId
        )
        var capturedDecisionId: UUID?
        let success = await runner.run {
            let result = try await container.rpc.requestGovernanceAction(input)
            capturedDecisionId = result.decisionId
        }
        if success, let decisionId = capturedDecisionId {
            pendingTransferDecisionId = decisionId
            isShowingTransferPicker = false
        }
    }

    private var transferGovernanceMessage: String {
        let resourceName = store.descriptor?.resource.displayName ?? "este recurso"
        let recipientName = contextMembersForTransfer
            .first(where: { $0.actorId == transferRecipientId })?
            .displayName ?? "el destinatario"
        return "Transferir propiedad de \(resourceName) a \(recipientName) requiere votación colectiva. Se creará una decisión para que los miembros aprueben."
    }

    private func transferDecisionTitle(recipientId: UUID) -> String {
        let resourceName = store.descriptor?.resource.displayName ?? "recurso"
        let recipientName = contextMembersForTransfer
            .first(where: { $0.actorId == recipientId })?
            .displayName ?? "miembro"
        return "Transferir \(resourceName) a \(recipientName)"
    }

    // MARK: - Descriptor List (R.5V.5 — Apple-native)

    @ViewBuilder
    private func descriptorList(_ d: ResourceDetailDescriptor) -> some View {
        List {
            heroSection(d)
            if d.conflicts.openCount > 0 {
                conflictsSection(d.conflicts)
            }
            informacionSection(d)
            if !d.widgets.isEmpty {
                dashboardSection(d.widgets, descriptor: d)
            }
            if !d.sections.isEmpty {
                seccionesSection(d)
            }
            // 2026-06-08 founder option B — todas las acciones viven en el "+"
            // del toolbar (resourceQuickActionsMenu). El body antes mostraba
            // hasta 6-7 Sections "Acciones · <group>" lo que era visualmente
            // pesado. Apple Wallet/Stocks-ish: el detail muestra info, las
            // acciones viven en el toolbar.
            if !d.relations.outbound.isEmpty || !d.relations.inbound.isEmpty {
                relacionesSection(d.relations)
            }
            linkedEventsSection(d.linkedEvents)
            linkedObligationsSection(d.linkedObligations)
            linkedDecisionsSection(d.linkedDecisions)
            linkedDocumentsSection
            if !d.activityPreview.isEmpty {
                activitySection(d.activityPreview)
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Hero

    @ViewBuilder
    private func heroSection(_ d: ResourceDetailDescriptor) -> some View {
        Section {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: d.subtype.icon ?? d.class.icon ?? "cube")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.Tint.primary)
                    .frame(width: 56, height: 56)
                    .background(Theme.Tint.primary.opacity(0.15), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(d.resource.displayName)
                        .font(.title3.bold())
                        .foregroundStyle(Theme.Text.primary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        chipBadge(d.subtype.displayName, tint: Theme.Tint.primary)
                        chipBadge(d.class.displayName, tint: Theme.Text.secondary)
                    }
                    if d.state.archived {
                        Text("Archivado")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.Tint.warning)
                    }
                }
                Spacer(minLength: 0)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 12, leading: 4, bottom: 4, trailing: 4))

            if !d.effectiveCapabilities.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(d.effectiveCapabilities, id: \.self) { cap in
                            Button {
                                explainedCapability = cap
                            } label: {
                                chipBadge(capabilityDisplayName(cap), tint: Theme.Tint.info)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
    }

    // MARK: - Conflicts (R.5B)

    @ViewBuilder
    private func conflictsSection(_ list: ResourceConflictList) -> some View {
        let critical = list.items.filter(\.isCritical).count
        Section {
            ForEach(list.items.prefix(4)) { item in
                Button {
                    guard !isResolvingConflict else { return }
                    pendingConflict = item
                    isShowingConflictDialog = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: conflictSeverityIcon(item.severity))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(conflictSeverityTint(item.severity))
                            .symbolEffect(
                                .pulse,
                                options: .repeating,
                                isActive: item.severity == "critical"
                            )
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.conflictTypeDisplay ?? item.conflictType)
                                .font(.callout)
                                .foregroundStyle(Theme.Text.primary)
                                .lineLimit(1)
                            Text(conflictRowSubtitle(item))
                                .font(.caption)
                                .foregroundStyle(Theme.Text.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                }
                .disabled(isResolvingConflict)
            }
            if list.items.count > 4 {
                Text("+ \(list.items.count - 4) más")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
            }
        } header: {
            Text("Conflictos abiertos")
        } footer: {
            Text(conflictsSubtitle(open: list.openCount, critical: critical))
        }
    }

    // MARK: - Información (type-aware metadata)
    //
    // 2026-06-09 — dispatch por descriptor.class.classKey. Antes mostraba los
    // mismos 4 fields para todos los tipos (Subtipo/Categoría/Estado/Valor).
    // Ahora cada clase resalta campos relevantes consumiendo metadata que ya
    // viene en el descriptor (metrics.balance/lastMovementAt, resource.
    // locationText/description, state.archivedAt). Cero backend changes.

    @ViewBuilder
    private func informacionSection(_ d: ResourceDetailDescriptor) -> some View {
        Section {
            // Estado y subtipo siempre — anchors comunes a todos los tipos.
            LabeledContent("Estado", value: estadoLabel(d))
            LabeledContent("Subtipo", value: d.subtype.displayName)

            // Fields específicos por clase.
            switch d.class.classKey {
            case "financial":
                financialFields(d)
            case "real_estate":
                realEstateFields(d)
            case "vehicle":
                vehicleFields(d)
            case "equipment":
                equipmentFields(d)
            case "document":
                documentFields(d)
            case "trip":
                tripFields(d)
            case "digital_asset":
                digitalAssetFields(d)
            default:
                genericFields(d)
            }

            // Descripción al final si existe (cualquier tipo).
            if let description = d.resource.description, !description.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Descripción")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.secondary)
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(Theme.Text.primary)
                }
            }
        } header: {
            Text("Información")
        }
    }

    private func estadoLabel(_ d: ResourceDetailDescriptor) -> String {
        if d.state.archived { return "Archivado" }
        switch d.state.status {
        case "active":    return "Activo"
        case "inactive":  return "Inactivo"
        case "pending":   return "Pendiente"
        case "completed": return "Completado"
        case "cancelled": return "Cancelado"
        default:          return d.state.status.capitalized
        }
    }

    @ViewBuilder
    private func financialFields(_ d: ResourceDetailDescriptor) -> some View {
        // Saldo es el campo headline de cualquier recurso financiero.
        if let balance = d.metrics.balance, let currency = d.metrics.currency {
            LabeledContent("Saldo") {
                Text(formatCurrency(balance, currency: currency))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.Tint.success)
            }
        }
        // 2026-06-09 — metadata type-specific (P2 audit)
        if let institution = d.resource.metadataString("institution") {
            LabeledContent("Institución", value: institution)
        }
        if let accountNumber = d.resource.metadataString("account_number") {
            LabeledContent("Cuenta") {
                Text(maskedAccountNumber(accountNumber))
                    .font(.callout.monospaced())
            }
        }
        if let walletAddress = d.resource.metadataString("wallet_address") {
            LabeledContent("Dirección") {
                Text(maskedAccountNumber(walletAddress))
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        if let lastMovement = d.metrics.lastMovementAt {
            LabeledContent("Último movimiento",
                value: lastMovement.formatted(date: .abbreviated, time: .shortened))
        }
        if let value = d.metrics.estimatedValue, let currency = d.metrics.currency,
           d.metrics.balance == nil {
            // Solo mostrar estimatedValue si no hay balance (ej. security).
            LabeledContent("Valor estimado", value: formatCurrency(value, currency: currency))
        }
    }

    @ViewBuilder
    private func realEstateFields(_ d: ResourceDetailDescriptor) -> some View {
        if let location = d.resource.locationText, !location.isEmpty {
            LabeledContent("Ubicación", value: location)
        }
        // 2026-06-09 — metadata type-specific
        if let area = d.resource.metadataString("area_sqm") {
            LabeledContent("Superficie", value: "\(area) m²")
        }
        if let bedrooms = d.resource.metadataString("bedrooms") {
            LabeledContent("Habitaciones", value: bedrooms)
        }
        if let bathrooms = d.resource.metadataString("bathrooms") {
            LabeledContent("Baños", value: bathrooms)
        }
        if let value = d.metrics.estimatedValue, let currency = d.metrics.currency {
            LabeledContent("Valor estimado", value: formatCurrency(value, currency: currency))
        }
    }

    @ViewBuilder
    private func vehicleFields(_ d: ResourceDetailDescriptor) -> some View {
        // 2026-06-09 — metadata type-specific (vehicle)
        if let make = d.resource.metadataString("make"),
           let model = d.resource.metadataString("model") {
            LabeledContent("Modelo", value: "\(make) \(model)")
        } else if let model = d.resource.metadataString("model") {
            LabeledContent("Modelo", value: model)
        }
        if let year = d.resource.metadataString("year") {
            LabeledContent("Año", value: year)
        }
        if let plate = d.resource.metadataString("license_plate") {
            LabeledContent("Placa") {
                Text(plate)
                    .font(.callout.monospaced())
            }
        }
        if let vin = d.resource.metadataString("vin") {
            LabeledContent("VIN") {
                Text(vin)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        if let location = d.resource.locationText, !location.isEmpty {
            LabeledContent("Ubicación", value: location)
        }
        if let value = d.metrics.estimatedValue, let currency = d.metrics.currency {
            LabeledContent("Valor estimado", value: formatCurrency(value, currency: currency))
        }
    }

    @ViewBuilder
    private func equipmentFields(_ d: ResourceDetailDescriptor) -> some View {
        if let make = d.resource.metadataString("make"),
           let model = d.resource.metadataString("model") {
            LabeledContent("Modelo", value: "\(make) \(model)")
        }
        if let serial = d.resource.metadataString("serial_number") {
            LabeledContent("Serie") {
                Text(serial)
                    .font(.callout.monospaced())
            }
        }
        if let location = d.resource.locationText, !location.isEmpty {
            LabeledContent("Ubicación", value: location)
        }
        if let value = d.metrics.estimatedValue, let currency = d.metrics.currency {
            LabeledContent("Valor estimado", value: formatCurrency(value, currency: currency))
        }
    }

    @ViewBuilder
    private func documentFields(_ d: ResourceDetailDescriptor) -> some View {
        // 2026-06-09 — metadata type-specific (document)
        if let partyA = d.resource.metadataString("party_a") {
            LabeledContent("Parte A", value: partyA)
        }
        if let partyB = d.resource.metadataString("party_b") {
            LabeledContent("Parte B", value: partyB)
        }
        if let effective = d.resource.metadataString("effective_date") {
            LabeledContent("Vigencia", value: effective)
        }
        if let expiration = d.resource.metadataString("expiration_date") {
            LabeledContent("Vence", value: expiration)
        }
        if let created = d.resource.createdAt {
            LabeledContent("Creado", value: created.formatted(date: .abbreviated, time: .omitted))
        }
        if d.state.lockedForGovernance {
            LabeledContent("Bloqueado") {
                Label("Decisión abierta", systemImage: "lock.fill")
                    .foregroundStyle(.purple)
            }
        }
    }

    @ViewBuilder
    private func tripFields(_ d: ResourceDetailDescriptor) -> some View {
        if let location = d.resource.locationText, !location.isEmpty {
            LabeledContent("Destino", value: location)
        }
        if let startDate = d.resource.metadataString("start_date") {
            LabeledContent("Inicio", value: startDate)
        }
        if let endDate = d.resource.metadataString("end_date") {
            LabeledContent("Fin", value: endDate)
        }
    }

    @ViewBuilder
    private func digitalAssetFields(_ d: ResourceDetailDescriptor) -> some View {
        if let platform = d.resource.metadataString("platform") {
            LabeledContent("Plataforma", value: platform)
        }
        if let url = d.resource.metadataString("url") {
            LabeledContent("URL") {
                Text(url)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        if let value = d.metrics.estimatedValue, let currency = d.metrics.currency {
            LabeledContent("Valor estimado", value: formatCurrency(value, currency: currency))
        }
    }

    /// Enmascara account numbers / wallet addresses para evitar exponer todos
    /// los dígitos en pantalla. Muestra primeros 2 + últimos 4.
    private func maskedAccountNumber(_ raw: String) -> String {
        guard raw.count > 8 else { return raw }
        let prefix = raw.prefix(2)
        let suffix = raw.suffix(4)
        return "\(prefix)••••\(suffix)"
    }

    @ViewBuilder
    private func genericFields(_ d: ResourceDetailDescriptor) -> some View {
        LabeledContent("Categoría", value: d.class.displayName)
        if let value = d.metrics.estimatedValue, let currency = d.metrics.currency {
            LabeledContent("Valor estimado", value: formatCurrency(value, currency: currency))
        }
    }

    // MARK: - Dashboard (widgets)

    @ViewBuilder
    private func dashboardSection(_ widgets: [ResourceWidget], descriptor: ResourceDetailDescriptor) -> some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                // R.5V.Glass.C2 founder feedback — mismo glass que childrenSection.
                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 12) {
                        ForEach(widgets) { widget in
                            widgetCard(widget, descriptor: descriptor)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } header: {
            Text("Dashboard")
        }
    }

    @ViewBuilder
    private func widgetCard(_ widget: ResourceWidget, descriptor: ResourceDetailDescriptor) -> some View {
        if resourceWidgetDestinationKey(widget.widgetKey) != nil {
            NavigationLink {
                resourceWidgetDestination(widgetKey: widget.widgetKey, descriptor: descriptor)
            } label: {
                widgetCardBody(widget, descriptor: descriptor, tappable: true)
            }
            .buttonStyle(.plain)
        } else {
            widgetCardBody(widget, descriptor: descriptor, tappable: false)
        }
    }

    /// Headline computado por widget key. Consume metrics + linked collections
    /// que ya vienen en el descriptor — sin RPC adicional. Si no hay data para
    /// ese widget, retorna nil y la card cae al layout plástico.
    private func widgetHeadline(_ widget: ResourceWidget, descriptor d: ResourceDetailDescriptor) -> (value: String, tint: Color)? {
        switch widget.widgetKey {
        case "balance_summary", "member_balance_summary":
            if let balance = d.metrics.balance, let currency = d.metrics.currency {
                return (formatCurrency(balance, currency: currency), Theme.Tint.success)
            }
        case "open_obligations":
            let count = d.linkedObligations.count
            if count > 0 {
                return ("\(count)", Theme.Tint.warning)
            }
        case "recent_activity":
            let count = d.activityPreview.count
            if count > 0 {
                return ("\(count)", Theme.Tint.info)
            }
        case "next_event":
            if let first = d.linkedEvents.first,
               case .object(let obj) = first,
               case .string(let s)? = obj["starts_at"],
               let date = ISO8601DateFormatter().date(from: s) {
                let isToday = Calendar.current.isDateInToday(date)
                let isTomorrow = Calendar.current.isDateInTomorrow(date)
                if isToday { return ("Hoy", Theme.Tint.warning) }
                if isTomorrow { return ("Mañana", Theme.Tint.warning) }
                return (date.formatted(.dateTime.day().month(.abbreviated)), Theme.Tint.primary)
            }
        case "income_summary":
            if let value = d.metrics.estimatedValue, let currency = d.metrics.currency {
                return (formatCurrency(value, currency: currency), Theme.Tint.success)
            }
        default:
            break
        }
        return nil
    }

    @ViewBuilder
    private func widgetCardBody(_ widget: ResourceWidget, descriptor: ResourceDetailDescriptor, tappable: Bool) -> some View {
        let headline = widgetHeadline(widget, descriptor: descriptor)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: widget.icon ?? "rectangle.stack")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(headline?.tint ?? Theme.Tint.primary)
                Spacer()
                if tappable {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.Text.tertiary)
                }
            }
            Spacer(minLength: 0)
            if let headline {
                // Headline real: número/fecha grande tinted + label como caption.
                Text(headline.value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(headline.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(widget.displayName)
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
                    .lineLimit(2)
            } else {
                // Sin data: layout plástico (título grande, sin caption técnica).
                Text(widget.displayName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(width: 150, height: 130, alignment: .topLeading)
        .padding(14)
        // R.5V.Glass.C2 founder feedback — Liquid Glass interactivo.
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
    }

    private func resourceWidgetDestinationKey(_ key: String) -> String? {
        switch key {
        case "balance_summary", "member_balance_summary", "income_summary",
             "lease_status", "open_obligations":
            return "money"
        case "next_event":                            return "events"
        case "recent_activity":                       return "activity"
        case "reservation_status", "upcoming_reservations": return "reservations"
        case "settlement_status":                     return "settlement"
        default:                                       return nil
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

    // MARK: - Secciones (descriptor.sections)
    //
    // 2026-06-08 founder feedback — antes había un Section con header literal
    // "Secciones" (meta naming anti-Apple) que listaba TODAS las secciones del
    // descriptor incluyendo las inertes con "Requiere: <capability>" expuesto
    // como texto técnico. Ahora:
    //   - Solo se renderizan secciones routeable (filtra por sectionDestinationKey)
    //   - Sin header — las rows quedan como NavigationLinks Apple-native
    //   - Sin "Requiere: X" — el backend ya gate la sección via capabilities

    @ViewBuilder
    private func seccionesSection(_ d: ResourceDetailDescriptor) -> some View {
        let routeable = d.sections.filter { sectionDestinationKey($0.sectionKey) != nil }
        if !routeable.isEmpty {
            Section {
                ForEach(routeable) { section in
                    NavigationLink {
                        sectionDestination(d, sectionKey: section.sectionKey)
                    } label: {
                        sectionRowContent(section)
                    }
                }
            }
        }
    }

    private func sectionDestinationKey(_ key: String) -> String? {
        switch key {
        case "reservations", "availability", "calendar", "activity", "settings": return key
        default: return nil
        }
    }

    @ViewBuilder
    private func sectionDestination(_ d: ResourceDetailDescriptor, sectionKey: String) -> some View {
        switch sectionKey {
        case "reservations":
            ReservationsListView(
                resource: d.resource,
                context: context,
                reservationContextId: nil,
                container: container
            )
        case "availability", "calendar":
            // R.5V.Calendar 2026-06-09 — calendar standalone del recurso
            // (reservaciones + eventos linked vía sourceEventId).
            ResourceCalendarView(resource: d.resource, context: context, container: container)
        case "activity":
            ActivityFeedView(context: context, container: container)
        case "settings":
            ResourceSettingsView(resourceId: resourceId, container: container)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func sectionRowContent(_ section: ResourceSection) -> some View {
        Label(section.displayName, systemImage: section.icon ?? "circle")
    }

    // MARK: - Acciones (toolbar-only, R.5V.X founder option B 2026-06-08)
    //
    // Anteriormente el body listaba todas las acciones en hasta 6-7 Sections
    // "Acciones · <group>" — visualmente pesado. Ahora viven únicamente en el
    // "+" Menu del toolbar (resourceQuickActionsMenu) agrupadas por section
    // semántica. Patrón Apple Wallet / Stocks / Files: el Detail muestra info,
    // el toolbar expone acciones.

    private func descriptorForm(for action: ResourceDescriptorAction) -> ResourceActionForm? {
        store.descriptor?.form(for: action.actionKey)
    }

    /// P0 fix 2026-06-08 — toolbar Menu con acciones descriptor-driven del recurso,
    /// AGRUPADAS por descriptor.section (Documentos / Permisos / Edición / etc.).
    /// Apple HIG: Menu con Sections para clusters semánticos. Dangerous actions
    /// (archivar / desligar) usan `role: .destructive`.
    @ViewBuilder
    private func resourceQuickActionsMenu(actions: [ResourceDescriptorAction], descriptor: ResourceDetailDescriptor) -> some View {
        let enabledActions = actions.filter { $0.enabled }
        if !enabledActions.isEmpty {
            let grouped = Dictionary(grouping: enabledActions, by: { $0.section })
            let orderedSections = grouped.keys.sorted(by: { resourceActionSectionOrder($0) < resourceActionSectionOrder($1) })

            Menu {
                ForEach(orderedSections, id: \.self) { sectionKey in
                    if let sectionActions = grouped[sectionKey], !sectionActions.isEmpty {
                        Section(resourceActionSectionLabel(sectionKey)) {
                            ForEach(sectionActions.sorted(by: { $0.label < $1.label })) { action in
                                let presentation = ActionPresentationCatalog.presentation(for: action.actionKey)
                                if action.dangerous {
                                    Button(role: .destructive) {
                                        handleActionTap(action)
                                    } label: {
                                        Label(action.label, systemImage: presentation.symbolName)
                                    }
                                } else {
                                    Button {
                                        handleActionTap(action)
                                    } label: {
                                        Label(action.label, systemImage: presentation.symbolName)
                                    }
                                }
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
            }
            .accessibilityLabel("Acciones del recurso")
        }
    }

    /// Orden estable de sections del resource_detail_descriptor.actions.
    private func resourceActionSectionOrder(_ section: String) -> Int {
        switch section {
        case "general":      return 0
        case "ownership":    return 1
        case "rights":       return 2
        case "documents":    return 3
        case "reservations": return 4
        case "monetary",
             "money":        return 5
        case "maintenance":  return 6
        case "relations":    return 7
        case "settings":     return 9
        default:             return 8
        }
    }

    /// Friendly label para sections del Menu.
    private func resourceActionSectionLabel(_ section: String) -> String {
        switch section {
        case "general":      return "General"
        case "ownership":    return "Propiedad"
        case "rights":       return "Derechos"
        case "documents":    return "Documentos"
        case "reservations": return "Reservaciones"
        case "monetary", "money": return "Dinero"
        case "maintenance":  return "Mantenimiento"
        case "relations":    return "Relaciones"
        case "settings":     return "Configuración"
        default:             return section.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

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

    // MARK: - Relations

    @ViewBuilder
    private func relacionesSection(_ relations: ResourceRelationsBundle) -> some View {
        Section {
            ForEach(relations.outbound + relations.inbound) { rel in
                NavigationLink {
                    ResourceDetailViewV2(resourceId: rel.otherResourceId, context: context, container: container)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rel.other.displayName)
                            Text(rel.relationType.replacingOccurrences(of: "_", with: " "))
                                .font(.caption)
                                .foregroundStyle(Theme.Text.secondary)
                        }
                    } icon: {
                        Image(systemName: rel.isOutbound ? "arrow.right" : "arrow.left")
                            .foregroundStyle(Theme.Text.secondary)
                    }
                }
            }
        } header: {
            Text("Relaciones")
        }
    }

    // MARK: - Linked Events / Obligations / Decisions

    @ViewBuilder
    private func linkedEventsSection(_ raw: [JSONValue]) -> some View {
        let items = parseLinkedEvents(raw)
        if !items.isEmpty {
            Section {
                ForEach(items) { ev in
                    NavigationLink {
                        EventDetailView(eventId: ev.id, context: context, container: container)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ev.title).lineLimit(1)
                                if let when = ev.startsAt {
                                    Text(when.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(Theme.Text.tertiary)
                                }
                            }
                        } icon: {
                            Image(systemName: "calendar").foregroundStyle(Theme.Tint.primary)
                        }
                    }
                }
            } header: {
                Text("Eventos relacionados")
            }
        }
    }

    @ViewBuilder
    private func linkedObligationsSection(_ raw: [JSONValue]) -> some View {
        let items = parseLinkedObligations(raw)
        if !items.isEmpty {
            Section {
                ForEach(items) { o in
                    NavigationLink {
                        ObligationDetailView(obligationId: o.id, context: context, container: container)
                    } label: {
                        HStack {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(o.title ?? o.kind ?? "Obligación").lineLimit(1)
                                    if let status = o.status {
                                        Text(status)
                                            .font(.caption)
                                            .foregroundStyle(Theme.Text.tertiary)
                                    }
                                }
                            } icon: {
                                Image(systemName: "doc.text").foregroundStyle(Theme.Text.secondary)
                            }
                            Spacer()
                            if let amount = o.amount, let cur = o.currency {
                                Text("\(Int(amount)) \(cur)")
                                    .font(.callout.bold())
                                    .foregroundStyle(Theme.Text.primary)
                            }
                        }
                    }
                }
            } header: {
                Text("Obligaciones relacionadas")
            }
        }
    }

    @ViewBuilder
    private func linkedDecisionsSection(_ raw: [JSONValue]) -> some View {
        let items = parseLinkedDecisions(raw)
        if !items.isEmpty {
            Section {
                ForEach(items) { dx in
                    NavigationLink {
                        DecisionDetailView(decisionId: dx.id, context: context, container: container)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dx.title).lineLimit(1)
                                HStack(spacing: 4) {
                                    if let tmpl = dx.templateKey {
                                        Text(tmpl)
                                    }
                                    if let st = dx.status {
                                        Text("· \(st)")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(Theme.Text.tertiary)
                            }
                        } icon: {
                            Image(systemName: "questionmark.circle").foregroundStyle(.purple)
                        }
                    }
                }
            } header: {
                Text("Decisiones relacionadas")
            }
        }
    }

    // MARK: - Documents (Documents V2 inline)

    @ViewBuilder
    private var linkedDocumentsSection: some View {
        let docs = documentsStore.documents
        if !docs.isEmpty {
            Section {
                ForEach(Array(docs.prefix(3))) { doc in
                    Button {
                        pushedDocumentId = doc.id
                    } label: {
                        HStack {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(doc.title)
                                        .foregroundStyle(Theme.Text.primary)
                                        .lineLimit(1)
                                    Text(doc.documentType.label)
                                        .font(.caption)
                                        .foregroundStyle(Theme.Text.secondary)
                                }
                            } icon: {
                                Image(systemName: doc.documentType.symbolName)
                                    .foregroundStyle(documentTint(doc.documentType))
                            }
                            Spacer()
                            if doc.isArchived {
                                RuulStatusBadge(.archived)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.Text.tertiary)
                        }
                    }
                }
                if docs.count > 3 {
                    Button {
                        isShowingAllDocuments = true
                    } label: {
                        Label("Ver todos (\(docs.count))", systemImage: "list.bullet")
                    }
                }
            } header: {
                Text("Documentos")
            }
        }
    }

    private func documentTint(_ type: DocumentType) -> Color {
        switch type {
        case .contract:  return Theme.Tint.info
        case .receipt:   return Theme.Tint.success
        case .id:        return .purple
        case .statement: return Theme.Tint.primary
        case .photo:     return Theme.Tint.warning
        case .other:     return Theme.Text.tertiary
        }
    }

    // MARK: - Activity

    @ViewBuilder
    private func activitySection(_ events: [ActivityPreviewEvent]) -> some View {
        Section {
            ForEach(events.prefix(5)) { ev in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "bolt.circle")
                        .foregroundStyle(Theme.Text.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ev.eventType.replacingOccurrences(of: ".", with: " · "))
                            .font(.callout)
                            .foregroundStyle(Theme.Text.primary)
                        if let when = ev.occurredAt {
                            Text(when.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(Theme.Text.tertiary)
                        }
                    }
                    Spacer()
                }
            }
            NavigationLink {
                ActivityFeedView(context: context, container: container)
            } label: {
                Label("Ver toda la actividad", systemImage: "list.bullet")
            }
        } header: {
            Text("Actividad reciente")
        }
    }

    // MARK: - JSONValue parsers (B.6.1)

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

    // MARK: - Capability catalog (snapshot estático)

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

    // MARK: - Conflict helpers (preservados)

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
        case "critical": return Theme.Tint.critical
        case "warning":  return Theme.Tint.warning
        case "info":     return Theme.Tint.info
        default:         return Theme.Text.secondary
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

    // MARK: - Chip + currency helpers

    @ViewBuilder
    private func chipBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
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

/// R.7.x — encapsula los 3 sheets del transfer flow (picker / governance / decision push)
/// para mantener el body de la view ligero (evita type-checker timeout).
private struct TransferFlowModifier: ViewModifier {
    @Binding var isShowingPicker: Bool
    @Binding var members: [ContextMember]
    @Binding var recipientId: UUID?
    @Binding var isShowingGovernanceSheet: Bool
    @Binding var pendingDecisionId: UUID?
    let resource: Resource?
    let context: AppContext
    let container: DependencyContainer
    let governanceMessage: String
    let onConfirmRecipient: () -> Void
    let onRequestGovernance: () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isShowingPicker) {
                TransferRecipientPicker(
                    members: members,
                    recipientId: $recipientId,
                    resourceName: resource?.displayName ?? "Recurso",
                    onCancel: { isShowingPicker = false },
                    onContinue: onConfirmRecipient
                )
            }
            .confirmationDialog(
                "Esta acción requiere aprobación",
                isPresented: $isShowingGovernanceSheet,
                titleVisibility: .visible
            ) {
                Button("Crear decisión") { onRequestGovernance() }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text(governanceMessage)
            }
            .sheet(item: Binding(
                get: { pendingDecisionId.map { TransferDecisionSheetWrapper(id: $0) } },
                set: { pendingDecisionId = $0?.id }
            )) { wrapper in
                NavigationStack {
                    DecisionDetailView(decisionId: wrapper.id, context: context, container: container)
                }
            }
    }
}

/// R.7.x — wrapper Identifiable para `.sheet(item:)` del push DecisionDetailView.
private struct TransferDecisionSheetWrapper: Identifiable {
    let id: UUID
}

/// R.7.x — picker dedicado para elegir el destinatario del transfer.
/// Apple-native: `List + Section`. Confirma habilitando "Continuar" sólo cuando
/// hay recipient seleccionado.
private struct TransferRecipientPicker: View {
    let members: [ContextMember]
    @Binding var recipientId: UUID?
    let resourceName: String
    let onCancel: () -> Void
    let onContinue: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if members.isEmpty {
                    Section {
                        Text("No hay miembros disponibles para recibir la propiedad.")
                            .foregroundStyle(Theme.Text.secondary)
                    }
                } else {
                    Section {
                        ForEach(members) { member in
                            Button {
                                recipientId = member.actorId
                            } label: {
                                HStack {
                                    Label {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(member.displayName)
                                                .foregroundStyle(Theme.Text.primary)
                                            if let type = member.membershipType {
                                                Text(type.capitalized)
                                                    .font(.caption)
                                                    .foregroundStyle(Theme.Text.secondary)
                                            }
                                        }
                                    } icon: {
                                        Image(systemName: "person.crop.circle")
                                            .foregroundStyle(Theme.Tint.primary)
                                    }
                                    Spacer()
                                    if recipientId == member.actorId {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Theme.Tint.primary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Elegí destinatario")
                    } footer: {
                        Text("La transferencia se propondrá como decisión para aprobación colectiva.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Transferir \(resourceName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continuar", action: onContinue)
                        .disabled(recipientId == nil)
                }
            }
        }
    }
}

fileprivate struct ConflictResolveAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
