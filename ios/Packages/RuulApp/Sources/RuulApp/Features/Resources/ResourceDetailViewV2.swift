import SwiftUI
import RuulCore

/// R.5A.F.1 + R.5V.5 — Resource Detail backed by `resource_detail_descriptor`.
///
/// **R.5V.5 (2026-06-07):** refactor visual a `List + Section` Apple-native.
/// Doctrina canónica DocumentDetailView (founder firmada 2026-06-07): la
/// Section ES la card. Cero VStack envueltos en `Theme.cardShape()`.
///
/// **R.10.A (2026-06-14):** monolito 1663 LOC fragmentado en 8 archivos
/// hermanos `ResourceDetailV2*.swift` (Hero/Conflicts/Info/Dashboard/Sections/
/// Linked/Actions/Transfer). Esta vista queda como orquestador puro:
/// state + body + descriptorList layout root + transfer business logic +
/// conflict resolution + handleActionTap dispatch. Cero behavior change.
///
/// Estructura visual:
/// ```
/// List(.insetGrouped) {
///   ResourceDetailV2HeroSection                    // hero + capabilities chips
///   ResourceDetailV2ConflictsSection (conditional) // R.5B
///   ResourceDetailV2InfoSection                    // LabeledContent type-aware
///   ResourceDetailV2DashboardSection (conditional) // widgets carousel
///   ResourceDetailV2SectionsSection                // NavigationLinks descriptor.sections
///   ResourceDetailV2RelationsSection (conditional)
///   ResourceDetailV2LinkedEventsSection (conditional)
///   ResourceDetailV2LinkedObligationsSection (conditional)
///   ResourceDetailV2LinkedDecisionsSection (conditional)
///   ResourceDetailV2LinkedDocumentsSection (conditional)
///   ResourceDetailV2ActivitySection (conditional)
/// }
/// ```
///
/// Lógica preservada en este archivo: descriptor store, conflicts dialog
/// modifier wiring, capability alert, native sheets (grant_right /
/// attach_document / edit_resource), action dispatcher (handleActionTap),
/// transfer flow business logic. Parsers y catalogs viven en archivos hijos.
public struct ResourceDetailViewV2: View {
    let resourceId: UUID
    let context: AppContext
    let container: DependencyContainer

    @State private var store: ResourceDescriptorStore
    @State private var pendingAction: PendingAction?
    @State private var documentsStore: DocumentsStore
    @State private var isShowingGrantRight = false
    @State private var isShowingAttachDocument = false
    @State private var isShowingEditResource = false
    @State private var explainedCapability: String?
    @State private var pendingConflict: ResourceConflict?
    @State private var isShowingConflictDialog = false
    @State private var conflictResolveAlert: ResourceDetailV2ConflictResolveAlert?
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
        //   - Trailing "ellipsis": Menu con drill-downs específicos del recurso.
        .toolbar {
            if let descriptor = store.descriptor, !descriptor.actions.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    ResourceDetailV2ActionsMenu(actions: descriptor.actions, onTap: handleActionTap)
                }
                // R.5V.Toolbar.Spacers — separa "+" (quick actions) del
                // "ellipsis" (más opciones) en cápsulas Liquid Glass distintas.
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // R.5Z.fix.2.a (founder 2026-06-09) — Menu plano sin Sections
                    // de 1 item. Apple HIG: usar Sections con headers solo cuando
                    // hay ≥2 items o agrupación significativa. Divider entre
                    // operacional y advanced.
                    Button {
                        isShowingEditResource = true
                    } label: {
                        Label("Editar recurso", systemImage: "pencil")
                    }
                    if !context.isPersonal, store.descriptor?.state.archived == false {
                        Button {
                            Task { await openTransferPicker() }
                        } label: {
                            Label("Transferir propiedad", systemImage: "arrow.left.arrow.right")
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
            explainedCapability.map { ResourceDetailV2CapabilityCatalog.displayName($0) } ?? "",
            isPresented: Binding(
                get: { explainedCapability != nil },
                set: { if !$0 { explainedCapability = nil } }
            ),
            presenting: explainedCapability
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { cap in
            Text(ResourceDetailV2CapabilityCatalog.description(cap))
        }
        .modifier(ResourceDetailV2ConflictsModifier(
            pendingConflict: $pendingConflict,
            isShowingDialog: $isShowingConflictDialog,
            alert: $conflictResolveAlert,
            isShowingAlert: $isShowingConflictAlert,
            dialogMessage: ResourceDetailV2ConflictsCopy.dialogMessage(_:),
            onKind: { conflict, kind in resolveConflict(conflict, kind: kind) }
        ))
        .modifier(ResourceDetailV2TransferFlowModifier(
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

    // MARK: - R.7.x transfer (business logic — usa store/container/runner/@State)

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

    // MARK: - Descriptor List (R.5V.5 — Apple-native, R.10.A orchestrator)

    @ViewBuilder
    private func descriptorList(_ d: ResourceDetailDescriptor) -> some View {
        List {
            ResourceDetailV2HeroSection(
                descriptor: d,
                explainedCapability: $explainedCapability,
                capabilityDisplayName: ResourceDetailV2CapabilityCatalog.displayName
            )
            if d.conflicts.openCount > 0 {
                ResourceDetailV2ConflictsSection(
                    list: d.conflicts,
                    isResolving: isResolvingConflict,
                    pendingConflict: $pendingConflict,
                    isShowingDialog: $isShowingConflictDialog
                )
            }
            ResourceDetailV2InfoSection(descriptor: d)
            if !d.widgets.isEmpty {
                ResourceDetailV2DashboardSection(
                    widgets: d.widgets,
                    descriptor: d,
                    context: context,
                    container: container
                )
            }
            if !d.sections.isEmpty {
                ResourceDetailV2SectionsSection(
                    descriptor: d,
                    resourceId: resourceId,
                    context: context,
                    container: container
                )
            }
            // 2026-06-08 founder option B — todas las acciones viven en el "+"
            // del toolbar (ResourceDetailV2ActionsMenu). El body antes mostraba
            // hasta 6-7 Sections "Acciones · <group>" lo que era visualmente
            // pesado. Apple Wallet/Stocks-ish: el detail muestra info, las
            // acciones viven en el toolbar.
            if !d.relations.outbound.isEmpty || !d.relations.inbound.isEmpty {
                ResourceDetailV2RelationsSection(relations: d.relations, context: context, container: container)
            }
            ResourceDetailV2LinkedEventsSection(raw: d.linkedEvents, context: context, container: container)
            ResourceDetailV2LinkedObligationsSection(raw: d.linkedObligations, context: context, container: container)
            ResourceDetailV2LinkedDecisionsSection(raw: d.linkedDecisions, context: context, container: container)
            ResourceDetailV2LinkedDocumentsSection(
                documents: documentsStore.documents,
                pushedDocumentId: $pushedDocumentId,
                isShowingAllDocuments: $isShowingAllDocuments
            )
            if !d.activityPreview.isEmpty {
                ResourceDetailV2ActivitySection(events: d.activityPreview, context: context, container: container)
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Action dispatcher

    private func descriptorForm(for action: ResourceDescriptorAction) -> ResourceActionForm? {
        store.descriptor?.form(for: action.actionKey)
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

    // MARK: - Conflict resolution (toca store + @State, queda aquí)

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
                    conflictResolveAlert = ResourceDetailV2ConflictResolveAlert(
                        title: "Sin cambios",
                        message: "El conflicto ya no estaba abierto."
                    )
                } else {
                    conflictResolveAlert = ResourceDetailV2ConflictResolveAlert(
                        title: ResourceDetailV2ConflictsCopy.resolveSuccessTitle(kind),
                        message: ResourceDetailV2ConflictsCopy.resolveSuccessMessage(kind, result: result)
                    )
                }
                isShowingConflictAlert = true
            } catch {
                conflictResolveAlert = ResourceDetailV2ConflictResolveAlert(
                    title: "No pudimos resolver",
                    message: UserFacingError.from(error).message
                )
                isShowingConflictAlert = true
            }
        }
    }
}

// MARK: - Previews

#Preview("Recurso — Casa Valle") {
    NavigationStack {
        ResourceDetailViewV2(
            resourceId: MockRuulRPCClient.DemoIds.casaValle,
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
