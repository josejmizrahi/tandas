import SwiftUI
import RuulCore

/// F.5 — detalle de un miembro: roles, antigüedad y acciones de admin
/// (asignar rol admin, remover del contexto).
public struct MemberDetailView: View {
    let member: ContextMember
    let context: AppContext
    let store: MembersStore
    let myActorId: UUID?
    /// R.2R — opcional: si llega, se renderiza la sección "Compromisos" del miembro.
    let container: DependencyContainer?

    @Environment(\.dismiss) private var dismiss
    @State private var runner = ActionRunner()
    @State private var isConfirmingRemove = false
    @State private var isConfirmingLeave = false
    /// R.2R — compromisos de acción donde este miembro es deudor o acreedor.
    @State private var memberObligations: [Obligation] = []
    @State private var selectedObligationId: UUID?
    @State private var isShowingCreateObligation = false
    /// R.7.E — actions canonical desde `member_available_actions` con `mode` decorado.
    /// Si `member.remove` viene con `mode=request_decision`, el flow de remove abre el
    /// sheet de governance en vez de invocar `remove_member` directo.
    @State private var memberActions: [AvailableAction] = []
    /// P1.5 — pausa directa (set_membership_state).
    @State private var isConfirmingPause = false
    @State private var pauseRunner = ActionRunner()
    /// R.7.F — flow genérico: la action seleccionada para el sheet de governance.
    /// Driver del título/copy dinámico del confirmationDialog.
    @State private var governanceAction: AvailableAction?
    /// R.7.E — sheet "Esta acción requiere aprobación" + push DecisionDetailView.
    @State private var isShowingGovernanceSheet = false
    @State private var governanceClientId: String = UUID().uuidString
    @State private var pendingDecisionId: UUID?

    public init(member: ContextMember, context: AppContext, store: MembersStore, myActorId: UUID?, container: DependencyContainer? = nil) {
        self.member = member
        self.context = context
        self.store = store
        self.myActorId = myActorId
        self.container = container
    }

    private var isMe: Bool { member.actorId == myActorId }

    public var body: some View {
        // R.5V.X 2026-06-08 — Apple-native canonical Detail pattern (V.4/V.5).
        List {
            // Hero
            Section {
                HStack(spacing: 14) {
                    ActorInitialsView(name: member.displayName, size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(member.displayName)
                            .font(.title3.bold())
                            .foregroundStyle(Theme.Text.primary)
                            .lineLimit(2)
                        if let type = member.membershipType {
                            Text(membershipTypeLabel(type))
                                .font(.subheadline)
                                .foregroundStyle(Theme.Text.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if isMe {
                        Text("Tú")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.Tint.primary)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 12, leading: 4, bottom: 4, trailing: 4))
            }

            Section {
                if let joined = member.joinedAt {
                    LabeledContent {
                        Text(joined.formatted(date: .abbreviated, time: .omitted))
                    } label: {
                        Label("Se unió", systemImage: "calendar")
                    }
                }
                LabeledContent {
                    Text(member.roles.isEmpty ? "Miembro" : member.roles.joined(separator: ", "))
                        .foregroundStyle(Theme.Text.primary)
                } label: {
                    Label("Roles", systemImage: "person.text.rectangle.fill")
                }
            } header: {
                Text("Información")
            }

            // R.2R — compromisos donde participa este miembro
            if container != nil, !context.isPersonal {
                obligationsSection
            }

            // R.5V.X 2026-06-08 founder option B — acciones admin del miembro
            // viven en el ellipsis Menu del toolbar (Apple Wallet pattern).
            // El body solo describe (Información, Compromisos). El toolbar
            // acciona (Roles / Compromisos / Gestión: promote/pause/remove).

            // Salir (si soy yo)
            if isMe && !context.isPersonal {
                Section {
                    Button(role: .destructive) {
                        isConfirmingLeave = true
                    } label: {
                        Label("Salir de \(context.displayName)", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(member.displayName)
        .navigationBarTitleDisplayMode(.inline)
        // P0 fix 2026-06-08 — toolbar Menu mirror de "Administración" Section
        // (Roles / Gestión). Acceso rápido desde header.
        .toolbar {
            if !isMe && store.canManageMembers(in: context) {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        let assignable = assignableRoles(for: member)
                        if !assignable.isEmpty {
                            Section("Roles") {
                                ForEach(assignable, id: \.key) { role in
                                    Button {
                                        Task {
                                            await runner.run {
                                                try await store.assignRole(
                                                    context: context,
                                                    memberActorId: member.actorId,
                                                    roleKey: role.key
                                                )
                                            }
                                        }
                                    } label: {
                                        Label("Asignar \(role.label)", systemImage: role.symbol)
                                    }
                                }
                            }
                        }
                        // R.5Z.fix.2.a — single-item "Compromisos" Section
                        // colapsada a bare Button con Divider (Apple HIG: no
                        // Section headers para 1 item).
                        if container != nil, !context.isPersonal {
                            Divider()
                            Button {
                                isShowingCreateObligation = true
                            } label: {
                                Label("Asignar compromiso", systemImage: "plus.circle.fill")
                            }
                        }
                        Section("Gestión") {
                            // R.7.F — promote via governance
                            if memberActions.contains(where: { $0.actionKey == "member.promote" && $0.enabled }) {
                                Button {
                                    handleMemberAction("member.promote")
                                } label: {
                                    Label("Promover a admin", systemImage: "person.badge.plus")
                                }
                            }
                            // R.7.F — pause via governance
                            if memberActions.contains(where: { $0.actionKey == "member.pause" && $0.enabled }) {
                                Button {
                                    handleMemberAction("member.pause")
                                } label: {
                                    Label("Pausar miembro", systemImage: "pause.circle")
                                }
                            }
                            Button(role: .destructive) {
                                handleMemberAction("member.remove")
                            } label: {
                                Label("Remover del contexto", systemImage: "person.badge.minus")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Acciones del miembro")
                }
            }
        }
        .task {
            await loadObligations()
            await loadMemberActions()
        }
        .sheet(item: Binding(get: { selectedObligationId.map { ObligationIdSheetWrapper(id: $0) } },
                              set: { selectedObligationId = $0?.id })) { wrapper in
            if let container {
                ObligationDetailView(obligationId: wrapper.id, context: context, container: container)
            }
        }
        .sheet(isPresented: $isShowingCreateObligation, onDismiss: {
            Task { await loadObligations() }
        }) {
            if let container {
                CreateObligationView(context: context, container: container, preselectedDebtorId: member.actorId)
            }
        }
        .actionErrorAlert(runner)
        .confirmationDialog(
            "¿Remover a \(member.displayName)?",
            isPresented: $isConfirmingRemove,
            titleVisibility: .visible
        ) {
            Button("Remover", role: .destructive) {
                Task {
                    let success = await runner.run {
                        try await store.removeMember(context: context, memberActorId: member.actorId, reason: nil)
                    }
                    if success { dismiss() }
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Perderá acceso a todo el contexto: eventos, recursos, dinero y actividad.")
        }
        // P1.5 — pausa directa (la policy del contexto no exige voto).
        .confirmationDialog(
            "¿Pausar a \(member.displayName)?",
            isPresented: $isConfirmingPause,
            titleVisibility: .visible
        ) {
            Button("Pausar", role: .destructive) {
                Task { await pauseMember() }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("No podrá operar en el contexto hasta que un administrador lo reactive.")
        }
        .actionErrorAlert(pauseRunner)
        // R.7.E/F — Governance sheet genérico para member.remove / pause / promote.
        .confirmationDialog(
            "Esta acción requiere aprobación",
            isPresented: $isShowingGovernanceSheet,
            titleVisibility: .visible
        ) {
            Button("Crear decisión") {
                Task { await requestGovernanceForSelectedAction() }
            }
            Button("Cancelar", role: .cancel) {
                governanceAction = nil
            }
        } message: {
            Text(governanceMessage)
        }
        // R.7.E — push DecisionDetailView cuando request_governance_action devuelve decision_id.
        .sheet(item: Binding(
            get: { pendingDecisionId.map { DecisionIdSheetWrapper(id: $0) } },
            set: { pendingDecisionId = $0?.id }
        )) { wrapper in
            if let container {
                NavigationStack {
                    DecisionDetailView(decisionId: wrapper.id, context: context, container: container)
                }
            }
        }
        .confirmationDialog(
            "¿Salir de \(context.displayName)?",
            isPresented: $isConfirmingLeave,
            titleVisibility: .visible
        ) {
            Button("Salir", role: .destructive) {
                Task {
                    let success = await runner.run {
                        try await store.leave(contextId: context.id)
                    }
                    if success { dismiss() }
                }
            }
            Button("Cancelar", role: .cancel) {}
        }
        .ruulCompactSheet()
    }

    // MARK: - R.2R obligations

    @ViewBuilder
    private var obligationsSection: some View {
        Section {
            if memberObligations.isEmpty {
                Label("Sin compromisos pendientes", systemImage: "checkmark.circle")
                    .foregroundStyle(Theme.Text.secondary)
            } else {
                ForEach(memberObligations.prefix(5)) { obligation in
                    Button {
                        selectedObligationId = obligation.id
                    } label: {
                        Label {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(obligation.title ?? obligation.kindLabel)
                                        .font(.callout.weight(.medium))
                                        .foregroundStyle(Theme.Text.primary)
                                        .lineLimit(1)
                                    Text(obligation.debtorActorId == member.actorId ? "Debe cumplir" : "Es acreedor")
                                        .font(.caption)
                                        .foregroundStyle(Theme.Text.secondary)
                                }
                                Spacer()
                                if let due = obligation.dueAt {
                                    Text(due.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(Theme.Text.tertiary)
                                }
                            }
                        } icon: {
                            Image(systemName: obligationSymbol(obligation.obligationKind))
                                .foregroundStyle(Theme.Tint.primary)
                        }
                    }
                }
            }
            // "Asignar compromiso" vive en el toolbar Menu (Section Compromisos)
            // — founder option B 2026-06-08: el body describe, el toolbar acciona.
        } header: {
            Text("Compromisos")
        } footer: {
            Text("Compromisos de acción donde \(member.displayName) participa.")
        }
    }

    private func membershipTypeLabel(_ type: String) -> String {
        switch type {
        case "founder": return "Fundador"
        case "admin":   return "Administrador"
        case "member":  return "Miembro"
        case "guest":   return "Invitado"
        case "viewer":  return "Observador"
        default:        return type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    // MARK: - R.7.E/F governance (flow genérico para remove/pause/promote)

    /// Tap genérico sobre cualquier action canonical del catalog. Branch:
    /// - Si la action reporta `mode=request_decision` → governance sheet.
    /// - Si NO está en el descriptor (no governance) y es `member.remove` → flow
    ///   legacy de remove_member directo con confirmationDialog destructive.
    /// - Sino, no-op (defensa: actions sin governance ni legacy path no se renderizan).
    private func handleMemberAction(_ actionKey: String) {
        let action = memberActions.first { $0.actionKey == actionKey }
        if action?.requiresDecision == true && container != nil {
            governanceAction = action
            governanceClientId = UUID().uuidString
            isShowingGovernanceSheet = true
        } else if actionKey == "member.remove" {
            isConfirmingRemove = true
        } else if actionKey == "member.pause" {
            // P1.5 — pausa directa cuando la policy del contexto no exige voto.
            // set_membership_state se auto-gatea en backend: si la policy cambió,
            // responde governance_required y el error sale por el runner.
            isConfirmingPause = true
        }
    }

    /// P1.5 — ejecuta la pausa directa.
    private func pauseMember() async {
        guard let container else { return }
        let ok = await pauseRunner.run {
            try await container.rpc.setMembershipState(
                contextId: context.id,
                memberActorId: member.actorId,
                targetState: "paused",
                reason: nil
            )
        }
        if ok {
            await store.load(context: context)
            await loadMemberActions()
        }
    }

    /// Copy dinámico para el sheet de governance según la action seleccionada.
    private var governanceMessage: String {
        switch governanceAction?.actionKey {
        case "member.remove":
            return "Remover a \(member.displayName) requiere votación colectiva. Se creará una decisión para que los miembros aprueben."
        case "member.pause":
            return "Pausar a \(member.displayName) requiere votación colectiva. Se creará una decisión para que los miembros aprueben."
        case "member.promote":
            return "Promover a \(member.displayName) a admin requiere votación colectiva. Se creará una decisión para que los miembros aprueben."
        default:
            return "Esta acción requiere votación colectiva. Se creará una decisión para que los miembros aprueben."
        }
    }

    /// Carga `member_available_actions` para decidir qué actions surface el descriptor
    /// + cómo gatear cada tap. Fail-silent: si falla, queda empty → solo `member.remove`
    /// queda accesible via flow legacy.
    private func loadMemberActions() async {
        guard let container, !context.isPersonal, let myId = myActorId else {
            memberActions = []
            return
        }
        do {
            memberActions = try await container.rpc.memberAvailableActions(
                contextId: context.id,
                memberActorId: member.actorId,
                actorId: myId
            )
        } catch {
            memberActions = []
        }
    }

    /// Invoca `request_governance_action` con clientId idempotency para la action
    /// actualmente seleccionada (governanceAction). Captura `decisionId` que dispara
    /// el sheet de DecisionDetailView. Reset `governanceAction` al terminar.
    private func requestGovernanceForSelectedAction() async {
        guard let container, let action = governanceAction else { return }
        let titlePrefix: String = {
            switch action.actionKey {
            case "member.remove":  return "Remover a"
            case "member.pause":   return "Pausar a"
            case "member.promote": return "Promover a admin a"
            default:               return action.label + " —"
            }
        }()
        let input = RequestGovernanceActionInput(
            contextActorId: context.id,
            actionKey: action.actionKey,
            targetType: "actor",
            targetId: member.actorId,
            payload: .object([:]),
            title: "\(titlePrefix) \(member.displayName)",
            closesAt: nil,
            clientId: governanceClientId
        )
        var capturedDecisionId: UUID?
        let success = await runner.run {
            let result = try await container.rpc.requestGovernanceAction(input)
            capturedDecisionId = result.decisionId
        }
        governanceAction = nil
        if success, let decisionId = capturedDecisionId {
            pendingDecisionId = decisionId
        }
    }

    private func loadObligations() async {
        guard let container, !context.isPersonal else {
            memberObligations = []
            return
        }
        do {
            let all = try await container.rpc.listObligations(contextId: context.id)
            memberObligations = all.filter { ob in
                ob.isActionKind && ob.isOpen
                    && (ob.debtorActorId == member.actorId || ob.creditorActorId == member.actorId)
            }
        } catch {
            memberObligations = []
        }
    }

    // MARK: - F.MEMBER.2 — role assignment catalog

    /// Catálogo de roles asignables. El backend (`roles` table) define hoy
    /// `admin` y `member` por contexto; el frontend no infiere comportamiento,
    /// solo presenta los keys disponibles y deja que el backend valide.
    private struct AssignableRole {
        let key: String
        let label: String
        let symbol: String
    }

    private static let roleCatalog: [AssignableRole] = [
        AssignableRole(key: "admin",  label: "Admin",   symbol: "person.badge.shield.checkmark"),
        AssignableRole(key: "member", label: "Miembro", symbol: "person.fill")
    ]

    private func assignableRoles(for member: ContextMember) -> [AssignableRole] {
        let current = Set(member.roles)
        return Self.roleCatalog.filter { !current.contains($0.key) }
    }

    private func obligationSymbol(_ kind: String) -> String {
        switch kind {
        case "action":      return "checklist"
        case "approval":    return "checkmark.seal.fill"
        case "delivery":    return "shippingbox.fill"
        case "attendance":  return "person.crop.circle.badge.checkmark.fill"
        case "document":    return "doc.text.fill"
        case "reservation": return "calendar.badge.clock"
        case "money":       return "dollarsign.circle.fill"
        default:            return "circle.dashed"
        }
    }
}

/// Wrapper Identifiable para `.sheet(item:)`.
private struct ObligationIdSheetWrapper: Identifiable {
    let id: UUID
}

/// R.7.E — wrapper Identifiable para presentar `DecisionDetailView` via `.sheet(item:)`.
private struct DecisionIdSheetWrapper: Identifiable {
    let id: UUID
}

#Preview("Detalle de miembro") {
    NavigationStack {
        MemberDetailView(
            member: ContextMember(
                actorId: MockRuulRPCClient.DemoIds.david,
                displayName: "David",
                membershipType: "member",
                joinedAt: Date(),
                roles: ["member"]
            ),
            context: AppContext(
                id: MockRuulRPCClient.DemoIds.cenaSemanal,
                kind: .collective,
                subtype: "friend_group",
                displayName: "Cena Semanal",
                roles: ["admin"]
            ),
            store: MembersStore(
                rpc: MockRuulRPCClient.demo(),
                previewMembers: [],
                permissions: MockRuulRPCClient.allPermissions
            ),
            myActorId: MockRuulRPCClient.DemoIds.jose
        )
    }
}
