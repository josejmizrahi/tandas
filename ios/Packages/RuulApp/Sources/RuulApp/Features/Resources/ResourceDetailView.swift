import SwiftUI
import Charts
import RuulCore

/// F.RESOURCE.2 — Resource Detail Apple-first, value-first.
///
/// Sentirse cerca de Wallet / Stocks / Home / Files. NUNCA un registro de DB.
///
/// Orden founder-locked:
/// 1. Header (icon + name + tipo + role) — toolbar •••
/// 2. Lo importante — métricas vivas por tipo (Saldo / Participación / Disponible / Último uso…)
/// 3. Qué puedes hacer — lista Settings-style desde `available_actions[]`
/// 4. Personas relacionadas — Propietarios (con %) + Beneficiarios (resumen)
/// 5. Relaciones — Pertenece a · Gobernado por
/// 6. Actividad reciente — máximo 5 + "Ver todo"
/// 7. Más — Otorgar derecho / Adjuntar / Auditoría / Configuración / Archivar
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
    @State private var resourceActivity: [ActivityEvent] = []
    @State private var isShowingFullActivity = false
    @State private var selectedParticipation: ResourceRight?
    @State private var isShowingAccessInfo = false
    /// F.RESOURCE.3 — sheet de edición de campos generales (no Settings).
    @State private var isShowingEdit = false

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
                RuulLoadingState()
            case .failed(let message):
                RuulErrorState(message: message) {
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
            if let detail = store.detail {
                toolbarMenu(for: detail)
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
        // F.RESOURCE.3 — edit inline (no Settings detour).
        .sheet(isPresented: $isShowingEdit) {
            if let detail = store.detail {
                EditResourceView(
                    resource: detail.resource,
                    container: container,
                    onSaved: {
                        Task { await store.load(resourceId: resourceId) }
                    }
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
        .sheet(isPresented: $isShowingAccessInfo) {
            if let detail = store.detail {
                NavigationStack {
                    AccessInfoSheet(
                        detail: detail,
                        context: context,
                        whyCanView: whyCanView,
                        myActorId: myActorId
                    )
                }
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
                primaryMetricSection(detail)
                reservationsSection(detail)
                locationSection(detail)
                peopleSection(detail)
                relationshipsSection(detail)
                documentsSection(detail)
                activitySection(detail)
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

    // MARK: - 1. Hero (icon + name + tipo + role)

    @ViewBuilder
    private func heroSection(_ detail: ResourceDetail) -> some View {
        VStack(spacing: 10) {
            Image(systemName: detail.resource.type.symbolName)
                .font(.system(size: 36))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 68, height: 68)
                .background(Color.accentColor.badgeFill, in: Circle())
            Text(detail.resource.displayName)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            Text(detail.resource.type.label)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let role = heroRoleLine(detail) {
                Text(role)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                    .multilineTextAlignment(.center)
            }
            if let description = detail.resource.description, !description.isEmpty {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    /// Una línea: "Dueño · 50%", "Beneficiario", "Administrador"…
    private func heroRoleLine(_ detail: ResourceDetail) -> String? {
        guard let actorId = myActorId else { return nil }
        let myRights = detail.rights.filter { $0.holderActorId == actorId }
        if myRights.isEmpty { return nil }

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

    // MARK: - 2. Lo importante (métricas vivas por tipo)

    private struct PrimaryDisplay {
        var heroLabel: String
        var heroValue: String
        var heroSymbol: String?
        var facts: [Fact] = []

        struct Fact: Hashable {
            let symbol: String?
            let label: String
            let value: String?
        }
    }

    @ViewBuilder
    private func primaryMetricSection(_ detail: ResourceDetail) -> some View {
        if let display = primaryDisplay(detail) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(display.heroLabel)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if let symbol = display.heroSymbol {
                            Image(systemName: symbol)
                                .font(.title2)
                                .foregroundStyle(.tint)
                        }
                        Text(display.heroValue)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                    }
                }
                if !display.facts.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(display.facts.enumerated()), id: \.offset) { idx, fact in
                            HStack(spacing: 10) {
                                if let symbol = fact.symbol {
                                    Image(systemName: symbol)
                                        .font(.subheadline)
                                        .foregroundStyle(.tint)
                                        .frame(width: 22)
                                }
                                Text(fact.label)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 8)
                                if let value = fact.value {
                                    Text(value)
                                        .font(.callout.weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.vertical, 10)
                            if idx < display.facts.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(Theme.Surface.card, in: Theme.cardShape(Theme.Radius.cardHero))
        }
    }

    /// Translation table de presentación: type → hero metric + facts.
    /// NO gatea acciones (eso lo hace `available_actions[]` del backend).
    /// Sólo elige qué mostrar de los datos ya cargados.
    private func primaryDisplay(_ detail: ResourceDetail) -> PrimaryDisplay? {
        let resource = detail.resource
        switch resource.type {
        case .bankAccount, .cashPool:
            return monetaryDisplay(detail, heroLabel: "Saldo actual")
        case .security, .trustAsset:
            return securityDisplay(detail)
        case .house, .property:
            return placeDisplay(detail)
        case .vehicle:
            return vehicleDisplay(detail)
        case .equipment:
            return equipmentDisplay(detail)
        case .digitalAsset, .game, .tripBooking, .contract, .document, .reservation, .other:
            return genericDisplay(detail)
        }
    }

    private func monetaryDisplay(_ detail: ResourceDetail, heroLabel: String) -> PrimaryDisplay {
        let participants = uniqueParticipantCount(detail)
        let heroValue: String
        if let amount = detail.resource.estimatedValue {
            heroValue = amount.currencyLabel(detail.resource.currency)
        } else {
            heroValue = "—"
        }
        var facts: [PrimaryDisplay.Fact] = []
        if participants > 0 {
            facts.append(.init(
                symbol: "person.2.fill",
                label: participants == 1 ? "Participante" : "Participantes",
                value: "\(participants)"
            ))
        }
        if let mgr = managerName(detail) {
            facts.append(.init(symbol: "person.crop.square.fill", label: "Administra", value: mgr))
        }
        return PrimaryDisplay(heroLabel: heroLabel, heroValue: heroValue, heroSymbol: nil, facts: facts)
    }

    private func securityDisplay(_ detail: ResourceDetail) -> PrimaryDisplay {
        var hero = ("Participación", "—", String?.none)
        if let pct = myOwnershipPercent(detail) {
            hero = ("Participación", "\(pct.formatted(.number.precision(.fractionLength(0...1))))%", nil)
        } else if let amount = detail.resource.estimatedValue {
            hero = ("Valor estimado", amount.currencyLabel(detail.resource.currency), nil)
        }
        var facts: [PrimaryDisplay.Fact] = []
        if let issuer = issuerName(detail) {
            facts.append(.init(symbol: "building.2.fill", label: "Emisor", value: issuer))
        }
        if let amount = detail.resource.estimatedValue, myOwnershipPercent(detail) != nil {
            facts.append(.init(
                symbol: "chart.line.uptrend.xyaxis",
                label: "Valor total",
                value: amount.currencyLabel(detail.resource.currency)
            ))
        }
        return PrimaryDisplay(heroLabel: hero.0, heroValue: hero.1, heroSymbol: hero.2, facts: facts)
    }

    private func placeDisplay(_ detail: ResourceDetail) -> PrimaryDisplay {
        var facts: [PrimaryDisplay.Fact] = []
        if let mgr = managerName(detail) {
            facts.append(.init(symbol: "person.crop.square.fill", label: "Responsable", value: mgr))
        }
        if let last = mostRecentActivity()?.formatted(.relative(presentation: .named)) {
            facts.append(.init(symbol: "clock", label: "Último movimiento", value: last))
        }
        return PrimaryDisplay(
            heroLabel: "Estado",
            heroValue: "Disponible",
            heroSymbol: "checkmark.circle.fill",
            facts: facts
        )
    }

    private func vehicleDisplay(_ detail: ResourceDetail) -> PrimaryDisplay {
        let lastValue = mostRecentActivity()?.formatted(.relative(presentation: .named)) ?? "—"
        var facts: [PrimaryDisplay.Fact] = []
        if let mgr = managerName(detail) {
            facts.append(.init(symbol: "person.crop.square.fill", label: "Responsable", value: mgr))
        }
        return PrimaryDisplay(
            heroLabel: "Último uso",
            heroValue: lastValue,
            heroSymbol: "clock",
            facts: facts
        )
    }

    private func equipmentDisplay(_ detail: ResourceDetail) -> PrimaryDisplay {
        var facts: [PrimaryDisplay.Fact] = []
        if let mgr = managerName(detail) {
            facts.append(.init(symbol: "person.crop.square.fill", label: "Responsable", value: mgr))
        }
        if let last = mostRecentActivity()?.formatted(.relative(presentation: .named)) {
            facts.append(.init(symbol: "clock", label: "Último uso", value: last))
        }
        let heroValue = detail.resource.estimatedValue?.currencyLabel(detail.resource.currency) ?? "Disponible"
        let heroLabel = detail.resource.estimatedValue != nil ? "Valor estimado" : "Estado"
        let heroSymbol: String? = detail.resource.estimatedValue == nil ? "checkmark.circle.fill" : nil
        return PrimaryDisplay(heroLabel: heroLabel, heroValue: heroValue, heroSymbol: heroSymbol, facts: facts)
    }

    private func genericDisplay(_ detail: ResourceDetail) -> PrimaryDisplay? {
        guard let amount = detail.resource.estimatedValue else {
            if let mgr = managerName(detail) {
                return PrimaryDisplay(
                    heroLabel: "Responsable",
                    heroValue: mgr,
                    heroSymbol: "person.fill",
                    facts: []
                )
            }
            return nil
        }
        return PrimaryDisplay(
            heroLabel: "Valor estimado",
            heroValue: amount.currencyLabel(detail.resource.currency),
            heroSymbol: nil,
            facts: []
        )
    }

    private func uniqueParticipantCount(_ detail: ResourceDetail) -> Int {
        Set(detail.rights.map(\.holderActorId)).count
    }

    private func managerName(_ detail: ResourceDetail) -> String? {
        detail.rights.first { $0.rightKind == "MANAGE" || $0.rightKind == "GOVERN" }?.holderDisplayName
            ?? detail.rights.first { $0.rightKind == "OWN" }?.holderDisplayName
    }

    private func issuerName(_ detail: ResourceDetail) -> String? {
        detail.rights.first { $0.rightKind == "GOVERN" }?.holderDisplayName
    }

    private func mostRecentActivity() -> Date? {
        resourceActivity.compactMap(\.occurredAt).max()
    }

    // MARK: - Toolbar menu (acciones + más)

    /// Action keys administrativas (van en la sección "Más" del menú).
    private let adminActionKeys: Set<String> = [
        "grant_right",
        "attach_document",
        "archive_resource",
        "delete_resource"
    ]

    @ToolbarContentBuilder
    private func toolbarMenu(for detail: ResourceDetail) -> some ToolbarContent {
        let primary = detail.availableActions.filter { !adminActionKeys.contains($0.actionKey) }
        let extras = moreMenuItems(for: detail)
        if !primary.isEmpty || !extras.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if !primary.isEmpty {
                        Section("Acciones") {
                            ForEach(primary) { action in
                                actionMenuButton(action)
                            }
                        }
                    }
                    if !extras.isEmpty {
                        Section("Más") {
                            ForEach(Array(extras.enumerated()), id: \.offset) { _, item in
                                Button(action: item.action) {
                                    Label(item.label, systemImage: item.symbol)
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Acciones del recurso")
            }
        }
    }

    @ViewBuilder
    private func actionMenuButton(_ action: AvailableAction) -> some View {
        let presentation = ActionPresentationCatalog.presentation(for: action.actionKey)
        Button {
            quickActionsRouter.open(ActionRouter.destination(for: action, in: .resource(resourceId)))
        } label: {
            Label(action.label, systemImage: presentation.symbolName)
        }
        .disabled(!action.enabled)
    }

    private struct MoreMenuItem {
        let symbol: String
        let label: String
        let action: () -> Void
    }

    private func moreMenuItems(for detail: ResourceDetail) -> [MoreMenuItem] {
        var items: [MoreMenuItem] = []
        if detail.can("grant_right") {
            items.append(MoreMenuItem(symbol: "key.fill", label: "Otorgar derecho") {
                isShowingGrantRight = true
            })
        }
        // F.RESOURCE.5 — attach_document ahora vive en resource_action_catalog.
        // El fallback canAttachDocuments(rights) era una F.2X violation
        // (infería UI desde derechos). El backend es la fuente de verdad.
        if detail.can("attach_document") {
            items.append(MoreMenuItem(symbol: "paperclip", label: "Adjuntar documento") {
                isShowingAttachDocument = true
            })
        }
        items.append(MoreMenuItem(symbol: "doc.text.magnifyingglass", label: "Ver auditoría") {
            if resourceActivity.isEmpty {
                Task {
                    await loadResourceActivity()
                    isShowingFullActivity = true
                }
            } else {
                isShowingFullActivity = true
            }
        })
        items.append(MoreMenuItem(symbol: "info.circle", label: "Información de acceso") {
            isShowingAccessInfo = true
        })
        if canShowSettings(detail) {
            items.append(MoreMenuItem(symbol: "gearshape", label: "Configuración") {
                isShowingSettings = true
            })
        }
        return items
    }

    // MARK: - 2.5 Reservaciones (visible cuando el recurso es reservable)

    /// Sección prominente con CTA "Hacer reservación" + acceso a la lista
    /// de reservaciones del recurso. Aparece sólo cuando el backend habilita
    /// `reserve_resource` para este actor (F.2X). La acción también vive en
    /// el menú `+` del toolbar, pero acá queda visible upfront por ser core.
    @ViewBuilder
    private func reservationsSection(_ detail: ResourceDetail) -> some View {
        let canReserve = detail.can("reserve_resource")
        let reservation = detail.availableActions.first { $0.actionKey == "reserve_resource" }
        if canReserve {
            VStack(alignment: .leading, spacing: 10) {
                Text("Reservaciones")
                    .font(.title3.weight(.semibold))
                VStack(spacing: 0) {
                    Button {
                        openReserveSheet()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "calendar.badge.clock")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.orange)
                                .frame(width: 28, height: 28)
                                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                            Text(reservation?.label ?? "Hacer reservación")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 56)
                    NavigationLink {
                        ReservationsListView(
                            resource: detail.resource,
                            context: context,
                            reservationContextId: governingContextId(detail),
                            container: container
                        )
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "calendar")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.tint)
                                .frame(width: 28, height: 28)
                                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                            Text("Ver reservaciones")
                                .font(.callout)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    // MARK: - 3.5 Ubicación (F.RESOURCE.4)

    /// Card simple de ubicación. Sólo aparece cuando `location_text` está
    /// seteado. Tap → abre Apple Maps con la dirección como query.
    @ViewBuilder
    private func locationSection(_ detail: ResourceDetail) -> some View {
        if let location = detail.resource.locationText, !location.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ubicación")
                    .font(.title3.weight(.semibold))
                Button {
                    openInMaps(location)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 32, height: 32)
                            .background(Color.accentColor.opacity(0.15), in: Circle())
                        Text(location)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .background(Theme.Surface.card, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func openInMaps(_ location: String) {
        let encoded = location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "http://maps.apple.com/?q=\(encoded)") {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - 4. Personas relacionadas

    @ViewBuilder
    private func peopleSection(_ detail: ResourceDetail) -> some View {
        let owners = detail.rights.filter { $0.rightKind == "OWN" }
        let beneficiaries = detail.rights.filter { $0.rightKind == "BENEFICIARY" }
        if !owners.isEmpty || !beneficiaries.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                if !owners.isEmpty {
                    ownersBlock(owners)
                }
                if !beneficiaries.isEmpty {
                    beneficiariosBlock(beneficiaries)
                }
            }
        }
    }

    @ViewBuilder
    private func ownersBlock(_ owners: [ResourceRight]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Propietarios")
                .font(.title3.weight(.semibold))
            ownershipDonut(owners)
            VStack(spacing: 0) {
                ForEach(Array(owners.enumerated()), id: \.offset) { idx, right in
                    Button {
                        selectedParticipation = right
                    } label: {
                        ownerRow(right)
                    }
                    .buttonStyle(.plain)
                    if idx < owners.count - 1 {
                        Divider().padding(.leading, Theme.Spacing.dividerLeading)
                    }
                }
            }
            .background(Theme.Surface.card, in: Theme.cardShape())
        }
    }

    /// Apple-native donut chart de participaciones (SectorMark). Aparece sólo
    /// cuando hay ≥2 dueños con `percent` válido — para un solo dueño no
    /// aporta información.
    @ViewBuilder
    private func ownershipDonut(_ owners: [ResourceRight]) -> some View {
        let chartable = owners.filter { ($0.percent ?? 0) > 0 }
        if chartable.count >= 2 {
            Chart(chartable, id: \.id) { right in
                SectorMark(
                    angle: .value("Participación", right.percent ?? 0),
                    innerRadius: .ratio(0.62),
                    angularInset: 1.5
                )
                .foregroundStyle(by: .value("Propietario", right.holderDisplayName ?? "—"))
                .cornerRadius(4)
            }
            .frame(height: 140)
            .padding(Theme.Spacing.md)
            .background(Theme.Surface.card, in: Theme.cardShape())
        }
    }

    @ViewBuilder
    private func ownerRow(_ right: ResourceRight) -> some View {
        HStack(spacing: 12) {
            ActorInitialsView(name: right.holderDisplayName ?? "Propietario", size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(right.holderDisplayName ?? "Propietario")
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let scope = right.scope, !scope.isEmpty {
                    Text(scope)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let percent = right.percent {
                Text("\(percent.formatted(.number.precision(.fractionLength(0...1))))%")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func beneficiariosBlock(_ beneficiaries: [ResourceRight]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Beneficiarios")
                .font(.title3.weight(.semibold))
            VStack(spacing: 0) {
                let preview = Array(beneficiaries.prefix(3))
                ForEach(Array(preview.enumerated()), id: \.offset) { idx, right in
                    Button {
                        selectedParticipation = right
                    } label: {
                        HStack(spacing: 12) {
                            ActorInitialsView(name: right.holderDisplayName ?? "Beneficiario", size: 32)
                            Text(right.holderDisplayName ?? "Beneficiario")
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if idx < preview.count - 1 {
                        Divider().padding(.leading, Theme.Spacing.dividerLeading)
                    }
                }
                if beneficiaries.count > 3 {
                    let extra = beneficiaries.count - 3
                    Divider().padding(.leading, Theme.Spacing.dividerLeading)
                    HStack {
                        Text("+\(extra) más")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
            .background(Theme.Surface.card, in: Theme.cardShape())
        }
    }

    // MARK: - 5. Relaciones

    @ViewBuilder
    private func relationshipsSection(_ detail: ResourceDetail) -> some View {
        let rows = relationshipRows(detail)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Relaciones")
                    .font(.title3.weight(.semibold))
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                        HStack(spacing: 12) {
                            Image(systemName: row.symbol)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.tint)
                                .frame(width: 28, height: 28)
                                .background(Color.accentColor.badgeFillSubtle, in: Theme.cardShape(Theme.Radius.chip))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(row.value)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        if idx < rows.count - 1 {
                            Divider().padding(.leading, Theme.Spacing.dividerLeading)
                        }
                    }
                }
                .background(Theme.Surface.card, in: Theme.cardShape())
            }
        }
    }

    private struct RelationshipRow: Hashable {
        let symbol: String
        let label: String
        let value: String
    }

    private func relationshipRows(_ detail: ResourceDetail) -> [RelationshipRow] {
        var rows: [RelationshipRow] = []
        rows.append(RelationshipRow(
            symbol: contextSymbol(context),
            label: "Pertenece a",
            value: context.displayName
        ))
        if let governorName = detail.rights.first(where: { $0.rightKind == "GOVERN" })?.holderDisplayName,
           !governorName.isEmpty {
            rows.append(RelationshipRow(
                symbol: "building.columns.fill",
                label: "Gobernado por",
                value: governorName
            ))
        }
        return rows
    }

    private func contextSymbol(_ ctx: AppContext) -> String {
        switch ctx.kind {
        case .person: return "person.fill"
        case .collective: return "person.3.fill"
        case .legalEntity: return "building.columns.fill"
        case .system: return "gear"
        }
    }

    // MARK: - 5.5 Documentos (inline, sin badge)

    @ViewBuilder
    private func documentsSection(_ detail: ResourceDetail) -> some View {
        if !documentsStore.documents.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Documentos")
                    .font(.title3.weight(.semibold))
                VStack(spacing: 0) {
                    ForEach(Array(documentsStore.documents.enumerated()), id: \.offset) { idx, doc in
                        Button {
                            Task { await openDocument(doc) }
                        } label: {
                            documentRow(doc)
                        }
                        .buttonStyle(.plain)
                        if idx < documentsStore.documents.count - 1 {
                            Divider().padding(.leading, Theme.Spacing.dividerLeading)
                        }
                    }
                }
                .background(Theme.Surface.card, in: Theme.cardShape())
            }
        }
    }

    @ViewBuilder
    private func documentRow(_ doc: Document) -> some View {
        HStack(spacing: 12) {
            Image(systemName: doc.documentType.symbolName)
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.badgeFillSubtle, in: Theme.cardShape(Theme.Radius.chip))
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

    private func openDocument(_ doc: Document) async {
        guard doc.storagePath != nil else { return }
        openingDocumentId = doc.id
        defer { openingDocumentId = nil }
        await runner.run {
            guard let url = try await documentsStore.signedURL(for: doc) else { return }
            await UIApplication.shared.open(url)
        }
    }

    // MARK: - 6. Actividad reciente

    @ViewBuilder
    private func activitySection(_ detail: ResourceDetail) -> some View {
        if !resourceActivity.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Actividad reciente")
                    .font(.title3.weight(.semibold))
                VStack(spacing: 0) {
                    let preview = Array(resourceActivity.prefix(5))
                    ForEach(Array(preview.enumerated()), id: \.offset) { idx, event in
                        activityRow(event)
                        if idx < preview.count - 1 {
                            Divider().padding(.leading, Theme.Spacing.dividerLeading)
                        }
                    }
                    if resourceActivity.count > 5 {
                        Divider().padding(.leading, 16)
                        Button {
                            isShowingFullActivity = true
                        } label: {
                            HStack {
                                Text("Ver actividad")
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.tint)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Theme.Surface.card, in: Theme.cardShape())
            }
        }
    }

    @ViewBuilder
    private func activityRow(_ event: ActivityEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.symbolName)
                .font(.callout)
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.badgeFillSubtle, in: Theme.cardShape(Theme.Radius.chip))
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
            resourceActivity = all.filter { event in
                event.resourceId == resourceId
                    || (event.subjectType == "resource" && event.subjectId == resourceId)
            }
        } catch {
            resourceActivity = []
        }
    }

    private func canShowSettings(_ detail: ResourceDetail) -> Bool {
        guard let actorId = myActorId else { return false }
        return detail.reasons(for: actorId).contains { $0.rightKind == "OWN" || $0.rightKind == "MANAGE" }
    }

    // MARK: - Follow toggle (al final, fuera del flujo principal)

    @ViewBuilder
    private func followToggleCard(_ detail: ResourceDetail) -> some View {
        let current = container.subscriptionsStore.current(targetType: .resource, targetId: resourceId)
        let isFollowing = current != nil

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
        .padding(16)
        .background(Theme.Surface.card, in: Theme.cardShape())
    }

    // MARK: - Helpers

    private func handleResourceAction(_ destination: ActionDestination) {
        switch destination.actionKey {
        case "reserve_resource":  openReserveSheet()
        case "attach_document":   isShowingAttachDocument = true
        case "grant_right":       isShowingGrantRight = true
        case "update_resource":   isShowingEdit = true
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

    /// Devuelve el porcentaje OWN del caller, si tiene.
    private func myOwnershipPercent(_ detail: ResourceDetail) -> Double? {
        guard let actorId = myActorId else { return nil }
        return detail.rights.first {
            $0.holderActorId == actorId && $0.rightKind == "OWN"
        }?.percent
    }

    private func loadWhyCanView() async {
        guard let actorId = myActorId else { return }
        whyCanView = try? await container.rpc.whyCanViewResource(
            actorId: actorId,
            resourceId: resourceId
        )
    }
}

// MARK: - Sheet: detalle de una participación

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
        .ruulSheet()
    }
}

// MARK: - Sheet: información de acceso (movido fuera del flujo principal)

private struct AccessInfoSheet: View {
    let detail: ResourceDetail
    let context: AppContext
    let whyCanView: WhyCanViewResource?
    let myActorId: UUID?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                if let why = whyCanView, !why.reasons.isEmpty {
                    ForEach(why.reasons, id: \.self) { reason in
                        Label(reason, systemImage: "checkmark.shield")
                    }
                } else if !detail.whyVisible.isEmpty {
                    ForEach(detail.whyVisible, id: \.self) { reason in
                        Label(reason, systemImage: "checkmark.shield")
                    }
                } else if let actorId = myActorId, !detail.reasons(for: actorId).isEmpty {
                    ForEach(detail.reasons(for: actorId)) { right in
                        Label(right.kindLabel, systemImage: rightSymbol(right.rightKind))
                    }
                } else {
                    Label("Lo ves a través de \(context.displayName)", systemImage: "person.3")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Por qué puedes ver este recurso")
            }
        }
        .navigationTitle("Información de acceso")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cerrar") { dismiss() }
            }
        }
        .ruulSheet()
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
        .ruulSheet()
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
