import SwiftUI
import RuulCore

/// F.RESOURCE.1 — Resource Detail Apple-native.
///
/// Jerarquía founder-locked:
/// 1. Hero (icon + name + tipo + role + valor + tu participación)
/// 2. Quick Actions (grid 2x2 desde available_actions)
/// 3. Actividad (filtrada por resourceId)
/// 4. Información (Participaciones bars cuando aplica)
/// 5. Beneficiarios (resumen)
/// 6. Documentos
/// 7. Derechos (collapsable agrupado)
/// 8. Información de acceso (collapsada)
/// 9. Seguir este recurso (toggle)
///
/// Cero `if resource.type ==`. Datos del backend driveen qué secciones aparecen.
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
    @State private var whyCanView: WhyCanViewResource?
    @State private var runner = ActionRunner()
    @State private var quickActionsRouter = NoopActionRouter()
    @State private var isShowingRequestReservation = false
    @State private var reservationsStore: ReservationsStore?
    /// F.RESOURCE.1 — actividad reciente del recurso (filtrada client-side).
    @State private var resourceActivity: [ActivityEvent] = []
    @State private var isShowingFullActivity = false
    @State private var selectedParticipation: ResourceRight?

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
                    detailScroll(detail)
                }
            }
        }
        .navigationTitle(store.detail?.resource.displayName ?? "Recurso")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
        .task {
            await store.load(resourceId: resourceId)
            await documentsStore.loadResourceDocuments(resourceId: resourceId)
            await loadWhyCanView()
            await loadResourceActivity()
            await container.subscriptionsStore.load()
        }
        .refreshable {
            await store.load(resourceId: resourceId)
            await documentsStore.loadResourceDocuments(resourceId: resourceId)
            await loadResourceActivity()
            await container.subscriptionsStore.load()
        }
        .refreshOnReappear(if: store.phase.isLoaded) {
            await store.load(resourceId: resourceId)
            await documentsStore.loadResourceDocuments(resourceId: resourceId)
        }
        .sheet(isPresented: $isShowingSettings) {
            ResourceSettingsView(resourceId: resourceId, container: container)
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
        .sheet(isPresented: $isShowingRequestReservation) {
            if let detail = store.detail, let resStore = reservationsStore {
                RequestReservationView(
                    resource: detail.resource,
                    context: context,
                    reservationContextId: governingContextId(detail),
                    store: resStore,
                    container: container
                )
            }
        }
        .sheet(isPresented: $isShowingFullActivity) {
            NavigationStack {
                ResourceActivityFullView(events: resourceActivity, container: container)
            }
        }
        .onChange(of: quickActionsRouter.lastOpened) { _, destination in
            guard let destination else { return }
            handleResourceAction(destination)
            quickActionsRouter.lastOpened = nil
        }
        .actionErrorAlert(runner)
    }

    // MARK: - Scroll container

    @ViewBuilder
    private func detailScroll(_ detail: ResourceDetail) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                heroSection(detail)
                resumenCard(detail)               // NUEVO F.RESOURCE.2
                quickActionsGrid(detail)
                activityCard(detail)
                participacionesCard(detail)
                beneficiariosCard(detail)
                rightsCard(detail)
                documentsCard(detail)
                accessInfoCard(detail)
                followToggleCard(detail)
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .sheet(item: $selectedParticipation) { right in
            NavigationStack {
                ParticipacionDetailSheet(right: right, resource: detail.resource)
            }
        }
    }

    // MARK: - 1. Hero

    @ViewBuilder
    private func heroSection(_ detail: ResourceDetail) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Image(systemName: detail.resource.type.symbolName)
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                    .frame(width: 80, height: 80)
                    .background(Color.accentColor.opacity(0.15), in: Circle())
                Text(detail.resource.displayName)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(detail.resource.type.label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                // F.RESOURCE.2 — role + relación (Beneficiario · Participación indirecta)
                if let storyLine = heroStoryLine(detail) {
                    Text(storyLine)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)
                        .multilineTextAlignment(.center)
                }
                if let description = detail.resource.description, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            }
            .padding(.top, 8)

            // Stats cards: valor estimado + tu participación
            let stats = heroStats(detail)
            if !stats.isEmpty {
                HStack(spacing: 12) {
                    ForEach(stats) { stat in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(stat.label).font(.caption).foregroundStyle(.secondary)
                            Text(stat.value).font(.title3.weight(.bold))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
        }
    }

    /// F.RESOURCE.2 — Story line: combina role + relación.
    /// "Beneficiario", "Beneficiario · Participación indirecta",
    /// "Dueño · 50%", "Administrador", etc.
    private func heroStoryLine(_ detail: ResourceDetail) -> String? {
        guard let actorId = myActorId else { return nil }
        let myRights = detail.rights.filter { $0.holderActorId == actorId }
        if myRights.isEmpty { return nil }

        // Primary: el right más fuerte que el caller tenga.
        let priority: [String] = ["OWN", "GOVERN", "MANAGE", "BENEFICIARY", "USE", "VIEW"]
        let primary = priority.compactMap { kind in
            myRights.first { $0.rightKind == kind }
        }.first
        guard let primary else { return myRights.first?.kindLabel }

        switch primary.rightKind {
        case "OWN":
            if let pct = primary.percent {
                return "Dueño · \(pct.formatted(.number.precision(.fractionLength(0...1))))%"
            }
            return "Propietario"
        case "GOVERN":
            return "Administrador del recurso"
        case "MANAGE":
            return "Administrador"
        case "BENEFICIARY":
            // Si NO tiene OWN, su participación es indirecta.
            let hasOwn = myRights.contains { $0.rightKind == "OWN" }
            return hasOwn ? "Beneficiario" : "Beneficiario · Participación indirecta"
        case "USE":
            return "Puedes usar"
        case "VIEW":
            return "Puedes ver"
        default:
            return primary.kindLabel
        }
    }

    private struct HeroStat: Identifiable {
        let id = UUID()
        let label: String
        let value: String
    }

    private func heroStats(_ detail: ResourceDetail) -> [HeroStat] {
        var out: [HeroStat] = []
        if let value = detail.resource.estimatedValue {
            out.append(HeroStat(label: "Valor estimado", value: value.currencyLabel(detail.resource.currency)))
        }
        if let percent = myOwnershipPercent(detail) {
            out.append(HeroStat(label: "Tu participación", value: "\(percent.formatted(.number.precision(.fractionLength(0...1))))%"))
        }
        return out
    }

    /// Devuelve el porcentaje OWN del caller, si tiene.
    private func myOwnershipPercent(_ detail: ResourceDetail) -> Double? {
        guard let actorId = myActorId else { return nil }
        return detail.rights.first {
            $0.holderActorId == actorId && $0.rightKind == "OWN"
        }?.percent
    }

    /// Traduce el primer right del caller a un role label humano.
    private func primaryRoleLabel(_ detail: ResourceDetail) -> String? {
        guard let actorId = myActorId else { return nil }
        let myRights = detail.rights.filter { $0.holderActorId == actorId }
        guard let primary = myRights.first(where: { $0.rightKind == "OWN" })
                            ?? myRights.first(where: { $0.rightKind == "MANAGE" })
                            ?? myRights.first(where: { $0.rightKind == "BENEFICIARY" })
                            ?? myRights.first(where: { $0.rightKind == "USE" })
                            ?? myRights.first(where: { $0.rightKind == "VIEW" })
                            ?? myRights.first
        else { return nil }
        return primary.kindLabel
    }

    // MARK: - Resumen (NUEVO F.RESOURCE.2)

    @ViewBuilder
    private func resumenCard(_ detail: ResourceDetail) -> some View {
        let owners = detail.rights.filter { $0.rightKind == "OWN" }.count
        let beneficiaries = detail.rights.filter { $0.rightKind == "BENEFICIARY" }.count
        let documents = documentsStore.documents.count
        let recentChanges = countRecentActivity()

        VStack(alignment: .leading, spacing: 12) {
            Text("Resumen")
                .font(.title3.weight(.semibold))
            HStack(spacing: 12) {
                resumenStat(value: "\(owners)", label: owners == 1 ? "Propietario" : "Propietarios")
                resumenStat(value: "\(beneficiaries)", label: beneficiaries == 1 ? "Beneficiario" : "Beneficiarios")
                resumenStat(value: "\(documents)", label: documents == 1 ? "Documento" : "Documentos")
                resumenStat(value: "\(recentChanges)", label: "Cambios", caption: "30 días")
            }
        }
    }

    @ViewBuilder
    private func resumenStat(value: String, label: String, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title2.weight(.bold)).foregroundStyle(.tint)
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    /// Cambios en los últimos 30 días.
    private func countRecentActivity() -> Int {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) else {
            return resourceActivity.count
        }
        return resourceActivity.filter { ($0.occurredAt ?? .distantPast) > cutoff }.count
    }

    // MARK: - 2. Quick Actions COMPACTAS (chips style)

    @ViewBuilder
    private func quickActionsGrid(_ detail: ResourceDetail) -> some View {
        let actions = detail.availableActions
        if !actions.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Acciones rápidas")
                    .font(.title3.weight(.semibold))
                // F.RESOURCE.2 — más compactas: 2 cols pero mucho menos altura.
                let columns = [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ]
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(actions) { action in
                        actionChip(action)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actionChip(_ action: AvailableAction) -> some View {
        let presentation = ActionPresentationCatalog.presentation(for: action.actionKey)
        Button {
            quickActionsRouter.open(ActionRouter.destination(for: action, in: .resource(resourceId)))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: presentation.symbolName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(action.enabled ? presentation.tint : Color.secondary)
                    .frame(width: 22)
                Text(action.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(action.enabled ? Color.primary : Color.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!action.enabled)
        .opacity(action.enabled ? 1.0 : 0.6)
        .accessibilityHint(action.reason ?? "")
    }

    // MARK: - 3. Activity

    @ViewBuilder
    private func activityCard(_ detail: ResourceDetail) -> some View {
        if !resourceActivity.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Actividad")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    if resourceActivity.count > 5 {
                        Button("Ver todo →") {
                            isShowingFullActivity = true
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                    }
                }
                VStack(spacing: 0) {
                    let preview = Array(resourceActivity.prefix(5))
                    ForEach(Array(preview.enumerated()), id: \.offset) { idx, event in
                        activityRow(event)
                        if idx < preview.count - 1 {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    @ViewBuilder
    private func activityRow(_ event: ActivityEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.symbolName)
                .font(.callout)
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(event.friendlyTitle(currentActorId: myActorId))
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let occurred = event.occurredAt {
                    Text(occurred.formatted(.relative(presentation: .named)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func loadResourceActivity() async {
        do {
            let all = try await container.rpc.listActivity(
                contextId: context.id,
                limit: 100,
                before: nil,
                includeDescendants: false
            )
            // F.RESOURCE.2 — el resource puede aparecer en resource_id O en
            // subject_id (cuando subject_type=="resource"). Ambas filtran.
            resourceActivity = all.filter { event in
                event.resourceId == resourceId
                    || (event.subjectType == "resource" && event.subjectId == resourceId)
            }
        } catch {
            resourceActivity = []
        }
    }

    // MARK: - 4. Información: Participaciones bars

    @ViewBuilder
    private func participacionesCard(_ detail: ResourceDetail) -> some View {
        let owners = detail.rights.filter { $0.rightKind == "OWN" }
        if !owners.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Participaciones")
                    .font(.title3.weight(.semibold))
                VStack(spacing: 10) {
                    ForEach(owners) { right in
                        participacionRow(right)
                    }
                }
                .padding(16)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    @ViewBuilder
    private func participacionRow(_ right: ResourceRight) -> some View {
        let percent = right.percent ?? 0
        Button {
            selectedParticipation = right
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(right.holderDisplayName ?? "Propietario")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(percent.formatted(.number.precision(.fractionLength(0...1))))%")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.tint)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.15))
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor)
                            .frame(width: max(0, geo.size.width * percent / 100.0))
                    }
                }
                .frame(height: 10)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 5. Beneficiarios

    @ViewBuilder
    private func beneficiariosCard(_ detail: ResourceDetail) -> some View {
        let beneficiaries = detail.rights.filter { $0.rightKind == "BENEFICIARY" }
        if !beneficiaries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Beneficiarios (\(beneficiaries.count))")
                        .font(.title3.weight(.semibold))
                    Spacer()
                }
                VStack(spacing: 0) {
                    let preview = Array(beneficiaries.prefix(3))
                    ForEach(Array(preview.enumerated()), id: \.offset) { idx, right in
                        HStack(spacing: 10) {
                            Image(systemName: "gift.fill")
                                .font(.subheadline)
                                .foregroundStyle(.pink)
                                .frame(width: 22)
                            Text(right.holderDisplayName ?? "Beneficiario")
                                .font(.callout)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        if idx < preview.count - 1 {
                            Divider().padding(.leading, 46)
                        }
                    }
                    if beneficiaries.count > 3 {
                        Divider().padding(.leading, 46)
                        HStack {
                            Text("Ver todos →")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    // MARK: - 6. Documentos

    @ViewBuilder
    private func documentsCard(_ detail: ResourceDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Documentos")
                    .font(.title3.weight(.semibold))
                Spacer()
                if canAttachDocuments(detail) {
                    Button {
                        isShowingAttachDocument = true
                    } label: {
                        Label("Agregar", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }

            VStack(spacing: 0) {
                if documentsStore.documents.isEmpty {
                    HStack {
                        Image(systemName: "doc")
                            .foregroundStyle(.secondary)
                        Text("Sin documentos adjuntos")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(16)
                } else {
                    ForEach(Array(documentsStore.documents.enumerated()), id: \.offset) { idx, doc in
                        Button {
                            Task { await openDocument(doc) }
                        } label: {
                            documentRow(doc)
                        }
                        .buttonStyle(.plain)
                        if idx < documentsStore.documents.count - 1 {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    @ViewBuilder
    private func documentRow(_ doc: Document) -> some View {
        HStack(spacing: 12) {
            Image(systemName: doc.documentType.symbolName)
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.title).font(.callout).lineLimit(1)
                HStack(spacing: 6) {
                    Text(doc.documentType.label)
                    if let size = doc.fileSizeLabel {
                        Text("·")
                        Text(size)
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if openingDocumentId == doc.id {
                ProgressView()
            } else if doc.storagePath != nil {
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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

    // MARK: - 7. Derechos (colapsable agrupado)

    @ViewBuilder
    private func rightsCard(_ detail: ResourceDetail) -> some View {
        let groups = groupRights(detail.rights)
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Derechos")
                    .font(.title3.weight(.semibold))
                VStack(spacing: 0) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { idx, group in
                        DisclosureGroup {
                            VStack(spacing: 0) {
                                ForEach(Array(group.rights.enumerated()), id: \.offset) { rIdx, right in
                                    HStack(spacing: 12) {
                                        Image(systemName: rightSymbol(right.rightKind))
                                            .foregroundStyle(.tint)
                                            .frame(width: 28)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(right.holderDisplayName ?? "Actor").font(.callout)
                                            if let percent = right.percent {
                                                Text("\(percent.formatted(.number.precision(.fractionLength(0...1))))%")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    if rIdx < group.rights.count - 1 {
                                        Divider().padding(.leading, 56)
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Text(group.title).font(.callout.weight(.semibold))
                                Spacer()
                                Text("\(group.rights.count)")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)

                        if idx < groups.count - 1 {
                            Divider().padding(.leading, 16)
                        }
                    }

                    if detail.can("grant_right") {
                        Divider().padding(.leading, 16)
                        Button {
                            isShowingGrantRight = true
                        } label: {
                            HStack {
                                Label("Otorgar derecho", systemImage: "plus")
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.tint)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private struct RightGroup {
        let title: String
        let rights: [ResourceRight]
    }

    private func groupRights(_ rights: [ResourceRight]) -> [RightGroup] {
        let buckets: [(String, [String])] = [
            ("Propietarios", ["OWN"]),
            ("Administradores", ["MANAGE", "GOVERN"]),
            ("Beneficiarios", ["BENEFICIARY"]),
            ("Acceso", ["USE", "VIEW"]),
            ("Otros", ["SELL", "TRANSFER", "LEASE", "LIEN", "APPROVE", "AUDIT"])
        ]
        return buckets.compactMap { (title, kinds) in
            let matched = rights.filter { kinds.contains($0.rightKind) }
            return matched.isEmpty ? nil : RightGroup(title: title, rights: matched)
        }
    }

    // MARK: - 8. Información de acceso (collapsada)

    @ViewBuilder
    private func accessInfoCard(_ detail: ResourceDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    if let why = whyCanView, !why.reasons.isEmpty {
                        ForEach(why.reasons, id: \.self) { reason in
                            Label(reason, systemImage: "checkmark.shield")
                                .font(.callout)
                        }
                    } else if !detail.whyVisible.isEmpty {
                        ForEach(detail.whyVisible, id: \.self) { reason in
                            Label(reason, systemImage: "checkmark.shield")
                                .font(.callout)
                        }
                    } else if let actorId = myActorId, !detail.reasons(for: actorId).isEmpty {
                        ForEach(detail.reasons(for: actorId)) { right in
                            Label(right.kindLabel, systemImage: rightSymbol(right.rightKind))
                                .font(.callout)
                        }
                    } else {
                        Label("Lo ves a través de \(context.displayName)", systemImage: "person.3")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 6)
            } label: {
                Label("Información de acceso", systemImage: "info.circle")
                    .font(.callout.weight(.semibold))
            }
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func loadWhyCanView() async {
        guard let actorId = myActorId else { return }
        whyCanView = try? await container.rpc.whyCanViewResource(
            actorId: actorId,
            resourceId: resourceId
        )
    }

    // MARK: - 9. Seguir este recurso (toggle simple)

    @ViewBuilder
    private func followToggleCard(_ detail: ResourceDetail) -> some View {
        let current = container.subscriptionsStore.current(targetType: .resource, targetId: resourceId)
        let isFollowing = current != nil

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: isFollowing ? "bell.fill" : "bell")
                    .font(.title3)
                    .foregroundStyle(isFollowing ? Color.accentColor : Color.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Seguir este recurso")
                        .font(.callout.weight(.semibold))
                    Text("Recibe actividad relevante cuando ocurran cambios.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { isFollowing },
                    set: { newValue in
                        Task {
                            await runner.run {
                                if newValue {
                                    _ = try await container.subscriptionsStore.subscribe(
                                        targetType: .resource,
                                        targetId: resourceId,
                                        subscriptionType: .watch
                                    )
                                } else if let sub = current {
                                    try await container.subscriptionsStore.unsubscribe(subscriptionId: sub.id)
                                }
                            }
                        }
                    }
                ))
                .labelsHidden()
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Helpers

    private func handleResourceAction(_ destination: ActionDestination) {
        switch destination.actionKey {
        case "reserve_resource":  openReserveSheet()
        case "attach_document":   isShowingAttachDocument = true
        case "grant_right":       isShowingGrantRight = true
        default:                  break
        }
    }

    private func openReserveSheet() {
        Task {
            if reservationsStore == nil {
                reservationsStore = ReservationsStore(
                    rpc: container.rpc,
                    myActorId: container.currentActorStore.actorId
                )
            }
            await reservationsStore?.load(resourceId: resourceId, context: context)
            isShowingRequestReservation = true
        }
    }

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
}

// MARK: - Sheet: detalle de una participación (F.RESOURCE.2)

/// Detalle simple de una participación (OWN right). F.RESOURCE.2 muestra
/// holder + porcentaje + ventana de tiempo. F.RESOURCE.3+ puede sumar
/// "cómo obtuvo" (history) y "qué controla" (cross-resource).
private struct ParticipacionDetailSheet: View {
    let right: ResourceRight
    let resource: Resource

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    ActorInitialsView(name: right.holderDisplayName ?? "Actor", size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(right.holderDisplayName ?? "Propietario")
                            .font(.title3.weight(.semibold))
                        Text(right.kindLabel)
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Participación") {
                if let pct = right.percent {
                    HStack {
                        Text("Porcentaje")
                        Spacer()
                        Text("\(pct.formatted(.number.precision(.fractionLength(0...2))))%")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
                if let scope = right.scope {
                    HStack {
                        Text("Alcance")
                        Spacer()
                        Text(scope).foregroundStyle(.secondary)
                    }
                }
                if let start = right.startsAt {
                    HStack {
                        Text("Vigente desde")
                        Spacer()
                        Text(start.formatted(date: .abbreviated, time: .omitted))
                            .foregroundStyle(.secondary)
                    }
                }
                if let end = right.endsAt {
                    HStack {
                        Text("Vence")
                        Spacer()
                        Text(end.formatted(date: .abbreviated, time: .omitted))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                HStack {
                    Text("En")
                    Spacer()
                    Text(resource.displayName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .navigationTitle("Participación")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cerrar") { dismiss() }
            }
        }
    }
}

// MARK: - Sheet: actividad completa del recurso

private struct ResourceActivityFullView: View {
    let events: [ActivityEvent]
    let container: DependencyContainer

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: event.symbolName)
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.friendlyTitle(currentActorId: container.currentActorStore.actorId))
                            .font(.callout)
                        if let occurred = event.occurredAt {
                            Text(occurred.formatted(.relative(presentation: .named)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            }
        }
        .navigationTitle("Actividad del recurso")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cerrar") { dismiss() }
            }
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
