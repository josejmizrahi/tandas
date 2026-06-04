import SwiftUI
import RuulCore

/// F.6 — detalle de un recurso. Explica **por qué aparece aquí** (los
/// derechos activos: OWN / USE / MANAGE / VIEW / BENEFICIARY / …) y permite
/// otorgar derechos y navegar a reservaciones.
public struct ResourceDetailView: View {
    let resourceId: UUID
    let context: AppContext
    let container: DependencyContainer

    @State private var store: ResourceDetailStore
    @State private var documentsStore: DocumentsStore
    @State private var isShowingGrantRight = false
    @State private var isShowingSettings = false
    @State private var isShowingAttachDocument = false
    @State private var openingDocumentId: UUID?
    @State private var runner = ActionRunner()

    public init(resourceId: UUID, context: AppContext, container: DependencyContainer) {
        self.resourceId = resourceId
        self.context = context
        self.container = container
        _store = State(initialValue: ResourceDetailStore(rpc: container.rpc))
        _documentsStore = State(initialValue: DocumentsStore(rpc: container.rpc))
    }

    private var myActorId: UUID? { container.currentActorStore.actorId }

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
                if let detail = store.detail {
                    detailList(detail)
                }
            }
        }
        .navigationTitle(store.detail?.resource.displayName ?? "Recurso")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // F.1A-3 — gear de Settings solo si el caller tiene OWN/MANAGE
            if let actorId = myActorId,
               let reasons = store.detail?.reasons(for: actorId),
               reasons.contains(where: { $0.rightKind == "OWN" || $0.rightKind == "MANAGE" }) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Configuración del recurso")
                }
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            ResourceSettingsView(resourceId: resourceId, container: container)
        }
        .task {
            await store.load(resourceId: resourceId)
            await documentsStore.loadResourceDocuments(resourceId: resourceId)
        }
        .refreshable {
            await store.load(resourceId: resourceId)
            await documentsStore.loadResourceDocuments(resourceId: resourceId)
        }
        .refreshOnReappear(if: store.phase.isLoaded) {
            await store.load(resourceId: resourceId)
            await documentsStore.loadResourceDocuments(resourceId: resourceId)
        }
        .sheet(isPresented: $isShowingGrantRight) {
            if let detail = store.detail {
                GrantRightSheet(resource: detail.resource, context: context, container: container) {
                    Task { await store.load(resourceId: resourceId) }
                }
            }
        }
        .sheet(isPresented: $isShowingAttachDocument) {
            if let detail = store.detail {
                AttachDocumentView(
                    resource: detail.resource,
                    context: context,
                    container: container,
                    store: documentsStore
                )
            }
        }
        .actionErrorAlert(runner)
    }

    @ViewBuilder
    private func detailList(_ detail: ResourceDetail) -> some View {
        List {
            headerSection(detail)
            whySection(detail)

            // R.2M-3: la UX se deriva de available_actions, NUNCA de resource_type.
            // Cada sección aparece solo si el backend ofrece una acción de esa sección.
            if !detail.actions(in: .reservations).isEmpty {
                reservationsSection(detail)
            }
            if !detail.actions(in: .money).isEmpty {
                actionSection(.money, detail: detail)
            }
            if !detail.actions(in: .beneficiaries).isEmpty {
                beneficiariesSection(detail)
            }
            if !detail.actions(in: .ownership).isEmpty {
                ownershipSection(detail)
            }
            documentsSection(detail)
            ForEach([ResourceActionSection.approvals, .maintenance, .audit], id: \.self) { section in
                if !detail.actions(in: section).isEmpty {
                    actionSection(section, detail: detail)
                }
            }

            rightsSection(detail)
        }
    }

    // MARK: Secciones

    @ViewBuilder
    private func headerSection(_ detail: ResourceDetail) -> some View {
        Section {
            HStack(spacing: 16) {
                Image(systemName: detail.resource.type.symbolName)
                    .font(.system(size: 32))
                    .foregroundStyle(.tint)
                    .frame(width: 56, height: 56)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(detail.resource.displayName)
                        .font(.headline)
                    Text(detail.resource.type.label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            if let description = detail.resource.description, !description.isEmpty {
                Text(description)
                    .font(.body)
            }
            if let value = detail.resource.estimatedValue {
                InfoRow(
                    symbolName: "banknote",
                    title: "Valor estimado",
                    value: value.currencyLabel(detail.resource.currency)
                )
            }
        }
    }

    /// "Por qué lo ves" — desde why_visible (backend); fallback a los rights del actor.
    @ViewBuilder
    private func whySection(_ detail: ResourceDetail) -> some View {
        Section("Por qué lo ves") {
            if !detail.whyVisible.isEmpty {
                ForEach(detail.whyVisible, id: \.self) { reason in
                    Label(reason, systemImage: "checkmark.shield")
                        .font(.callout)
                }
            } else if let myActorId, !detail.reasons(for: myActorId).isEmpty {
                ForEach(detail.reasons(for: myActorId)) { right in
                    Label(right.kindLabel, systemImage: rightSymbol(right.rightKind))
                        .font(.callout)
                }
            } else {
                Label("Lo ves a través de \(context.displayName)", systemImage: "person.3")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Reservaciones — única sección con pantalla operativa propia (resource-scoped).
    @ViewBuilder
    private func reservationsSection(_ detail: ResourceDetail) -> some View {
        Section {
            NavigationLink {
                ReservationsListView(
                    resource: detail.resource,
                    context: context,
                    reservationContextId: governingContextId(detail),
                    container: container
                )
            } label: {
                Label("Reservaciones", systemImage: ResourceActionSection.reservations.symbolName)
            }
        } footer: {
            Text("Quien tenga derecho de uso (USE/MANAGE/OWN) puede solicitar reservar este recurso.")
        }
    }

    /// Beneficiarios — lista los rights BENEFICIARY reales + acciones disponibles.
    @ViewBuilder
    private func beneficiariesSection(_ detail: ResourceDetail) -> some View {
        Section(ResourceActionSection.beneficiaries.title) {
            let beneficiaries = detail.rights.filter { $0.rightKind == RightKind.beneficiary.rawValue }
            if beneficiaries.isEmpty {
                Text("Sin beneficiarios designados todavía")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(beneficiaries) { right in
                    Label(right.holderDisplayName ?? "Actor", systemImage: "gift.fill")
                        .font(.callout)
                }
            }
            ForEach(detail.actions(in: .beneficiaries)) { action in
                actionRow(action)
            }
        }
    }

    /// Participaciones — lista los OWN con porcentaje + acciones de propiedad.
    @ViewBuilder
    private func ownershipSection(_ detail: ResourceDetail) -> some View {
        Section(ResourceActionSection.ownership.title) {
            let owners = detail.rights.filter { $0.rightKind == RightKind.own.rawValue }
            ForEach(owners) { right in
                InfoRow(
                    symbolName: "person.crop.circle",
                    title: right.holderDisplayName ?? "Actor",
                    value: right.percent.map { "\($0.formatted(.number))%" }
                )
            }
            ForEach(detail.actions(in: .ownership)) { action in
                actionRow(action)
            }
        }
    }

    /// Documentos adjuntos al recurso. Cualquiera que pueda VER el recurso ve
    /// los documentos (el backend filtra por RLS); el botón "Adjuntar" gatea
    /// con `documents.manage` del contexto (fallback: si el caller llegó hasta
    /// aquí y tiene OWN/USE/MANAGE, le permitimos intentar — RLS server-side decide).
    @ViewBuilder
    private func documentsSection(_ detail: ResourceDetail) -> some View {
        Section("Documentos") {
            if documentsStore.documents.isEmpty {
                Text(documentsStore.phase.isLoading
                    ? "Cargando documentos…"
                    : "Aún no hay documentos adjuntos.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(documentsStore.documents) { doc in
                    Button {
                        Task { await openDocument(doc) }
                    } label: {
                        documentRow(doc)
                    }
                    .buttonStyle(.plain)
                }
            }

            if canAttachDocuments(detail) {
                Button {
                    isShowingAttachDocument = true
                } label: {
                    Label("Adjuntar documento", systemImage: "paperclip")
                }
            }
        }
    }

    @ViewBuilder
    private func documentRow(_ doc: Document) -> some View {
        HStack(spacing: 12) {
            Image(systemName: doc.documentType.symbolName)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.title)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(doc.documentType.label)
                    if let size = doc.fileSizeLabel {
                        Text("·")
                        Text(size)
                    }
                    if let created = doc.createdAt {
                        Text("·")
                        Text(created.formatted(.relative(presentation: .named)))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            if openingDocumentId == doc.id {
                ProgressView()
            } else if doc.storagePath != nil {
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private func canAttachDocuments(_ detail: ResourceDetail) -> Bool {
        guard let actorId = myActorId else { return false }
        let rights = detail.reasons(for: actorId).map(\.rightKind)
        return rights.contains(where: { ["OWN", "MANAGE", "USE"].contains($0) })
    }

    private func openDocument(_ doc: Document) async {
        guard doc.storagePath != nil else { return }
        openingDocumentId = doc.id
        defer { openingDocumentId = nil }
        await runner.run {
            guard let url = try await documentsStore.signedURL(for: doc) else { return }
            await UIApplication.shared.open(url)
        }
    }

    /// Sección genérica que renderiza las available_actions de una sección.
    @ViewBuilder
    private func actionSection(_ section: ResourceActionSection, detail: ResourceDetail) -> some View {
        Section(section.title) {
            ForEach(detail.actions(in: section)) { action in
                actionRow(action)
            }
        }
    }

    /// Fila de acción disponible. Las acciones sin pantalla operativa propia se
    /// muestran como affordance (lo que el actor PUEDE hacer), sin inventar UI falsa.
    @ViewBuilder
    private func actionRow(_ action: AvailableAction) -> some View {
        Label(action.label, systemImage: ResourceActionSection(rawValue: action.section)?.symbolName ?? "circle")
            .font(.callout)
            .foregroundStyle(action.enabled ? .primary : .secondary)
    }

    /// Derechos activos sobre el recurso + otorgar (gated por available_actions).
    @ViewBuilder
    private func rightsSection(_ detail: ResourceDetail) -> some View {
        Section(ResourceActionSection.rights.title) {
            ForEach(detail.rights) { right in
                HStack {
                    Image(systemName: rightSymbol(right.rightKind))
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(right.holderDisplayName ?? "Actor")
                        Text(right.kindLabel + (right.percent.map { " · \($0.formatted(.number))%" } ?? ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusBadge(right.rightKind, color: rightColor(right.rightKind))
                }
                .swipeActions(edge: .trailing) {
                    if detail.can("grant_right") {
                        Button("Revocar", role: .destructive) {
                            Task {
                                await runner.run {
                                    try await store.revokeRight(rightId: right.rightId, resourceId: resourceId)
                                }
                            }
                        }
                    }
                }
            }

            if detail.can("grant_right") {
                Button {
                    isShowingGrantRight = true
                } label: {
                    Label("Otorgar derecho", systemImage: "plus")
                }
            }
        }
    }

    /// El contexto que gobierna las reservaciones del recurso: el holder del
    /// right GOVERN. Si no hay GOVERN, el contexto desde el que se navega.
    private func governingContextId(_ detail: ResourceDetail) -> UUID {
        detail.rights.first { $0.rightKind == "GOVERN" }?.holderActorId ?? context.id
    }

    private func rightSymbol(_ kind: String) -> String {
        switch RightKind(rawValue: kind) {
        case .own: return "crown.fill"
        case .use: return "hand.raised.fill"
        case .manage: return "gearshape.fill"
        case .view: return "eye.fill"
        case .govern: return "checkmark.seal.fill"
        case .beneficiary: return "gift.fill"
        case .sell, .transfer: return "arrow.left.arrow.right"
        case .lease: return "key.fill"
        case .lien: return "lock.fill"
        case .approve: return "checkmark.circle.fill"
        case .audit: return "doc.text.magnifyingglass"
        case .none: return "questionmark.circle"
        }
    }

    private func rightColor(_ kind: String) -> Color {
        switch RightKind(rawValue: kind) {
        case .own: return .purple
        case .use: return .blue
        case .manage: return .orange
        case .view: return .gray
        case .govern: return .indigo
        case .beneficiary: return .pink
        default: return .secondary
        }
    }
}

#Preview("Casa Valle") {
    NavigationStack {
        ResourceDetailView(
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
