import SwiftUI
import RuulCore

/// Detail surface for a single member inside a group (Primitiva 1 +
/// 11 + 12 + 17 + 18 surfaces). Read-only Foundation slice — replaces
/// the direct push to `MemberHistoryView` from the boundary list.
///
/// Pattern: Contacts.app card scroll — a centred identity hero on top
/// followed by a stack of `Section`s. Sections collapse to invisible
/// when they have no data (per `doctrine_group_space_situational`).
///
/// Stores consumed:
/// - `sanctionsStore`   — group-wide list, filtered locally by
///   `targetMembershipId == memberItem.membershipId`.
/// - `reputationStore`  — events for THIS subject only; loaded on
///   `.task` via `refreshIfNeeded`.
/// - `moneyStore`       — only used when the member IS the caller
///   (the RPCs are keyed to the caller's own membership).
/// - `rolesStore`       — drives the Edit Roles sheet (Primitiva 17).
/// - `membersStore`     — refreshed after assign/revoke so the inline
///   role list reflects the new server state without a parent rebuild.
public struct MemberDetailView: View {
    @Bindable var sanctionsStore: SanctionsStore
    @Bindable var reputationStore: ReputationStore
    @Bindable var moneyStore: MoneyStore
    @Bindable var rolesStore: RolesStore
    @Bindable var membersStore: MembersStore
    let groupId: UUID
    let memberItem: MembershipBoundaryItem
    /// V3 Batch B-1 — fetch fire-and-forget para la timeline del
    /// miembro. Inyectado para que las views derivadas (preview, tests)
    /// puedan pasar fixtures sin tocar Supabase.
    let activityFetcher: (UUID, UUID, Int) async throws -> [GroupEvent]
    /// V3 Batch B-1 (Quick Actions) — fetcher de permisos del caller en
    /// el grupo (`list_member_permissions(p_group_id, p_user_id=NULL)`).
    /// Default vacío para previews → buttons quedan ocultos.
    let permissionsFetcher: (UUID) async throws -> [String]
    /// V3-D.20 — fetcher de membership_provenance. Default `nil` retorna
    /// `nil` y la sección "Origen del estado" no se renderea.
    let provenanceFetcher: (UUID) async throws -> MembershipProvenance?
    /// Opt-in. Cuando los 3 stores se proveen + hay perms suficientes,
    /// MemberDetailView renderiza Quick Actions con sheets directos.
    /// Nil = la sección queda invisible (back-compat para previews).
    let quickActionStores: QuickActionStores?
    /// V3-D.20.1 — opt-in. When both are provided AND the displayed
    /// member is `banned` AND caller has `members.update`, the state
    /// actions section renders a "Proponer decisión de reinstate"
    /// button that opens an inline ProposeDecisionSheet pre-filled with
    /// template_key=decision.membership_reinstate. Nil at either =
    /// fall back to the legacy text-only hint.
    let decisionsStore: DecisionsStore?
    let decisionsRepository: CanonicalDecisionsRepository?

    @State private var isManagingRoles: Bool = false
    /// V3 Batch B-1 — Activity feed local. `nil` mientras carga; `[]`
    /// cuando confirmadamente vacío (fallback silencioso si la RPC
    /// falla).
    @State private var activity: [GroupEvent]? = nil
    /// V3 Batch B-1 — caller permissions resueltos server-side. Set
    /// vacío inicial = nada visible (fail-closed UX).
    @State private var callerPermissions: Set<String> = []
    /// V3-D.20 — provenance del estado de membresía. Lazy load.
    @State private var membershipProvenance: MembershipProvenance?

    /// How many recent history rows to render inline before linking out
    /// to the full `MemberHistoryView`.
    private let recentHistoryLimit = 5
    private let activityLimit = 8

    /// Bundle de los 3 stores write-side necesarios para los Quick
    /// Actions. Separado del init principal para que call sites con
    /// container solo pasen `.from(container)`.
    public struct QuickActionStores {
        public let mandates: MandatesStore
        public let reputationFeed: ReputationFeedStore
        public init(mandates: MandatesStore, reputationFeed: ReputationFeedStore) {
            self.mandates = mandates
            self.reputationFeed = reputationFeed
        }
    }

    public init(
        sanctionsStore: SanctionsStore,
        reputationStore: ReputationStore,
        moneyStore: MoneyStore,
        rolesStore: RolesStore,
        membersStore: MembersStore,
        groupId: UUID,
        memberItem: MembershipBoundaryItem,
        activityFetcher: @escaping (UUID, UUID, Int) async throws -> [GroupEvent] = { _, _, _ in [] },
        permissionsFetcher: @escaping (UUID) async throws -> [String] = { _ in [] },
        provenanceFetcher: @escaping (UUID) async throws -> MembershipProvenance? = { _ in nil },
        quickActionStores: QuickActionStores? = nil,
        decisionsStore: DecisionsStore? = nil,
        decisionsRepository: CanonicalDecisionsRepository? = nil
    ) {
        self.sanctionsStore = sanctionsStore
        self.reputationStore = reputationStore
        self.moneyStore = moneyStore
        self.rolesStore = rolesStore
        self.membersStore = membersStore
        self.groupId = groupId
        self.memberItem = memberItem
        self.activityFetcher = activityFetcher
        self.permissionsFetcher = permissionsFetcher
        self.provenanceFetcher = provenanceFetcher
        self.quickActionStores = quickActionStores
        self.decisionsStore = decisionsStore
        self.decisionsRepository = decisionsRepository
    }

    /// Live projection of the member — picks up the latest snapshot
    /// from `membersStore` (refreshed after assign/revoke) and falls
    /// back to the originally-passed item.
    private var displayedItem: MembershipBoundaryItem {
        membersStore.items.first(where: { $0.id == memberItem.id }) ?? memberItem
    }

    public var body: some View {
        let item = displayedItem
        return List {
            identitySection(item: item)
            quickActionsSection(item: item)
            rolesSection(item: item)
            sanctionsSection(item: item)
            peerMoneySection(item: item)
            if item.isCurrentUser {
                moneySection
            }
            activitySection(item: item)
            provenanceSection(item: item)
            historySection(item: item)
            stateActionsSection(item: item)
        }
        .navigationTitle(L10n.MemberDetail.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: MemberFullHistoryDestination.self) { _ in
            MemberHistoryView(
                store: reputationStore,
                groupId: groupId,
                memberItem: item
            )
        }
        .sheet(isPresented: $isManagingRoles) {
            ManageMemberRolesSheet(
                rolesStore: rolesStore,
                membersStore: membersStore,
                groupId: groupId,
                memberItem: item
            )
        }
        .sheet(isPresented: $membersStore.isStateSheetPresented) {
            MembershipStateSheet(store: membersStore, groupId: groupId)
        }
        .alert(
            "Se abrió una votación",
            isPresented: membershipDecisionOpenedBinding,
            presenting: membershipDecisionOpenedFromOutcome
        ) { _ in
            Button("Entendido", role: .cancel) { membersStore.clearGovernanceOutcome() }
        } message: { _ in
            Text("Se abrió una decisión sobre la membresía. Se ejecutará cuando pase la votación.")
        }
        .task {
            if let mid = item.membershipId {
                await reputationStore.refreshIfNeeded(
                    groupId: groupId,
                    subjectMembershipId: mid,
                    limit: 50
                )
                await loadActivity(membershipId: mid)
            }
            await sanctionsStore.refreshIfNeeded(groupId: groupId)
            await rolesStore.refreshIfNeeded(groupId: groupId)
            await loadPermissions()
            if let mid = item.membershipId {
                await loadMembershipProvenance(membershipId: mid)
            }
        }
        .sheet(isPresented: sanctionSheetBinding) {
            IssueSanctionSheet(
                store: sanctionsStore,
                membersStore: membersStore,
                groupId: groupId
            )
        }
        .sheet(isPresented: mandateSheetBinding) {
            if let mandates = quickActionStores?.mandates {
                GrantMandateSheet(
                    store: mandates,
                    membersStore: membersStore,
                    groupId: groupId
                )
            }
        }
        .sheet(isPresented: reputationSheetBinding) {
            if let feed = quickActionStores?.reputationFeed {
                RecordReputationEventSheet(
                    store: feed,
                    membersStore: membersStore,
                    groupId: groupId
                )
            }
        }
        .sheet(isPresented: proposeReinstateSheetBinding) {
            if let decisionsStore {
                ProposeDecisionSheet(
                    store: decisionsStore,
                    groupId: groupId,
                    sanctionsStore: nil,
                    mandatesStore: nil,
                    membersStore: membersStore,
                    rulesStore: nil,
                    decisionsRepository: decisionsRepository
                )
            }
        }
        .refreshable {
            if let mid = item.membershipId {
                await reputationStore.refresh(
                    groupId: groupId,
                    subjectMembershipId: mid,
                    limit: 50
                )
                await loadActivity(membershipId: mid)
            }
            await sanctionsStore.refresh(groupId: groupId)
            await rolesStore.refresh(groupId: groupId)
        }
    }

    private func loadActivity(membershipId: UUID) async {
        do {
            activity = try await activityFetcher(groupId, membershipId, activityLimit)
        } catch {
            // Silent: la timeline no es load-bearing, el bloque queda invisible.
            activity = []
        }
    }

    private func loadPermissions() async {
        do {
            callerPermissions = Set(try await permissionsFetcher(groupId))
        } catch {
            callerPermissions = []
        }
    }

    private func loadMembershipProvenance(membershipId: UUID) async {
        do {
            membershipProvenance = try await provenanceFetcher(membershipId)
        } catch {
            // Silent: la sección queda invisible.
            membershipProvenance = nil
        }
    }

    // V3-D.20 — "Origen del estado". Sección inline reutilizando el
    // patrón visual de DecisionDetailView D.18 provenance.
    @ViewBuilder
    private func provenanceSection(item: MembershipBoundaryItem) -> some View {
        if let p = membershipProvenance, p.found,
           p.membershipId == item.membershipId {
            Section("Origen del estado") {
                if let state = p.currentState {
                    LabeledContent("Estado actual", value: state)
                }
                if let reason = p.currentReason, !reason.isEmpty {
                    LabeledContent("Raz\u{00f3}n", value: reason)
                }
                if let last = p.lastTransition {
                    LabeledContent("\u{00DA}ltima transici\u{00F3}n", value: last.eventType)
                    if let at = last.at {
                        LabeledContent("Cu\u{00e1}ndo") {
                            Text(at, format: .dateTime.day().month().year().hour().minute())
                        }
                    }
                }
                if let decision = p.sourceDecision {
                    LabeledContent("Decisi\u{00f3}n origen", value: decision.title ?? decision.decisionId.uuidString)
                }
                if let ruleTitle = p.sourceRuleTitle {
                    LabeledContent("Regla origen", value: ruleTitle)
                }
                if let via = p.joinedVia {
                    LabeledContent("Ingres\u{00f3} v\u{00ed}a", value: via)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - V3 Batch B-1 — Quick Actions (gated por perms server-side)

    /// Universal Detail bloque 6 (Actions). Renderiza solo cuando:
    /// 1. Hay stores write-side disponibles (`quickActionStores != nil`).
    /// 2. El displayed NO es el caller (no tiene sentido sancionarse a
    ///    sí mismo desde acá; el flow self vive en otros sheets).
    /// 3. El displayed tiene membership_id (no es invite pendiente).
    /// 4. El caller tiene AL MENOS un permiso aplicable a este target.
    @ViewBuilder
    private func quickActionsSection(item: MembershipBoundaryItem) -> some View {
        if let stores = quickActionStores,
           !item.isCurrentUser,
           let mid = item.membershipId,
           hasAnyQuickAction
        {
            Section("Acciones rápidas") {
                if callerPermissions.contains("sanctions.create") {
                    Button {
                        sanctionsStore.beginIssuing(defaultTarget: mid)
                    } label: {
                        Label("Sancionar a \(item.displayName)", systemImage: "exclamationmark.shield")
                    }
                }
                if callerPermissions.contains("mandates.grant") {
                    Button {
                        stores.mandates.beginGranting(defaultRepresentative: mid)
                    } label: {
                        Label("Otorgar mandato a \(item.displayName)", systemImage: "person.2")
                    }
                }
                if callerPermissions.contains("reputation.record") {
                    Button {
                        stores.reputationFeed.beginRecording(defaultSubject: mid)
                    } label: {
                        Label("Registrar reputación sobre \(item.displayName)", systemImage: "star.bubble")
                    }
                }
            }
        }
    }

    private var hasAnyQuickAction: Bool {
        callerPermissions.contains("sanctions.create")
        || callerPermissions.contains("mandates.grant")
        || callerPermissions.contains("reputation.record")
    }

    private var sanctionSheetBinding: Binding<Bool> {
        Binding(
            get: { sanctionsStore.isIssuePresented },
            set: { sanctionsStore.isIssuePresented = $0 }
        )
    }
    private var mandateSheetBinding: Binding<Bool> {
        Binding(
            get: { quickActionStores?.mandates.isGrantPresented ?? false },
            set: { quickActionStores?.mandates.isGrantPresented = $0 }
        )
    }
    private var reputationSheetBinding: Binding<Bool> {
        Binding(
            get: { quickActionStores?.reputationFeed.isRecordPresented ?? false },
            set: { quickActionStores?.reputationFeed.isRecordPresented = $0 }
        )
    }
    /// V3-D.20.1 — sheet binding for the inline reinstate-decision
    /// proposal. Backed by `decisionsStore.isProposePresented` so that
    /// `beginProposingMembershipReinstate(...)` opens the sheet and
    /// the sheet's own Cancel/Save buttons dismiss it via the same
    /// shared flag. Nil store collapses to a permanently-false binding.
    private var proposeReinstateSheetBinding: Binding<Bool> {
        Binding(
            get: { decisionsStore?.isProposePresented ?? false },
            set: { newValue in decisionsStore?.isProposePresented = newValue }
        )
    }

    /// D.22 — surfaces `lastGovernanceOutcome.decisionOpened` for ban/remove
    /// flows so the member sees an alert instead of a silent close.
    private var membershipDecisionOpenedBinding: Binding<Bool> {
        Binding(
            get: { membershipDecisionOpenedFromOutcome != nil },
            set: { newValue in
                if !newValue { membersStore.clearGovernanceOutcome() }
            }
        )
    }

    private var membershipDecisionOpenedFromOutcome: DecisionOpenedDetails? {
        if case .decisionOpened(let details) = membersStore.lastGovernanceOutcome {
            return details
        }
        return nil
    }

    // MARK: - Identity

    @ViewBuilder
    private func identitySection(item: MembershipBoundaryItem) -> some View {
        Section {
            VStack(spacing: 12) {
                MemberAvatarView(item: item)
                    .frame(width: 96, height: 96)

                VStack(spacing: 4) {
                    Text(item.displayName)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    if let username = item.username, !username.isEmpty {
                        Text("@\(username)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if item.status != .active {
                    MembershipStatusBadge(status: item.status)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            LabeledContent {
                Text(item.membershipType.label)
            } label: {
                Text(L10n.MemberDetail.memberTypeLabel)
            }

            if let joined = item.joinedAt {
                LabeledContent {
                    Text(joined, format: .dateTime.day().month().year())
                } label: {
                    Text(L10n.MemberDetail.joinedAtLabel)
                }
            }
        }
    }

    // MARK: - Roles

    @ViewBuilder
    private func rolesSection(item: MembershipBoundaryItem) -> some View {
        // Manage button is only meaningful for real memberships; pending
        // invites have no membership id to target. Backend gates the
        // mutation by `roles.manage` — we surface its error if denied.
        Section(L10n.MemberDetail.rolesSection) {
            if item.roleNames.isEmpty {
                Text(L10n.MemberDetail.rolesEmpty)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(item.roleNames, id: \.self) { roleName in
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.rectangle.badge.checkmark")
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        Text(roleName)
                            .font(.body)
                    }
                }
            }
            if item.membershipId != nil {
                Button {
                    isManagingRoles = true
                } label: {
                    Label(L10n.MemberDetail.manageRolesButton, systemImage: "pencil")
                }
            }
        }
    }

    // MARK: - Sanciones (filtered to this member)

    @ViewBuilder
    private func sanctionsSection(item: MembershipBoundaryItem) -> some View {
        let mine = filteredSanctions(for: item)
        // Hide entirely when there are none AND the store has finished
        // loading without an error — empty cluster = invisible.
        if !mine.isEmpty {
            Section(L10n.MemberDetail.sanctionsSection) {
                ForEach(mine) { sanction in
                    SanctionRowView(sanction: sanction)
                }
            }
        }
    }

    private func filteredSanctions(for item: MembershipBoundaryItem) -> [GroupSanction] {
        guard let mid = item.membershipId else { return [] }
        return sanctionsStore.sanctions.filter { $0.targetMembershipId == mid }
    }

    // MARK: - Money "Entre miembros" (peer-pair from caller's plan)

    /// Doctrina `doctrine_money_two_worlds`: cuando miras a otra
    /// persona, la pregunta más concreta es "¿en qué estamos en
    /// plata?". Tomamos el `settlementPlan` ya hidratado por
    /// `MoneyStore.refresh(...)` y lo filtramos por contraparte.
    ///
    /// Visibilidad:
    /// - Self → cluster propio (`moneySection`) maneja el caso.
    /// - Other con membership_id → siempre se muestra (incluso "al día"
    ///   responde una pregunta concreta).
    /// - Invite pendiente (no membership_id) → invisible.
    @ViewBuilder
    private func peerMoneySection(item: MembershipBoundaryItem) -> some View {
        if !item.isCurrentUser, let mid = item.membershipId {
            let peer = moneyStore.settlementPlan.first(where: { $0.counterpartyMembershipId == mid })
            Section("Entre ustedes") {
                if let peer {
                    peerMoneyRow(peer: peer, displayName: item.displayName)
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                            .frame(width: 24)
                        Text("Están al día.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func peerMoneyRow(peer: SettlementPlanItem, displayName: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: peer.direction == .youOwe
                  ? "arrow.up.right.circle.fill"
                  : "arrow.down.left.circle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(peerHeadline(direction: peer.direction, name: displayName))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("\(peer.absoluteAmount.formatted()) \(peer.unit)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Doctrina `doctrine_money_two_worlds`: cada string nombra a la
    /// contraparte. Coincide con `SettleUpView.headline(for:)` para
    /// mantener vocabulario consistente.
    private func peerHeadline(direction: SettlementPlanItem.Direction, name: String) -> String {
        switch direction {
        case .youOwe:  return "Págale a \(name)"
        case .theyOwe: return "\(name) te debe"
        }
    }

    // MARK: - Money (self only)

    @ViewBuilder
    private var moneySection: some View {
        Section(L10n.MemberDetail.moneySection) {
            if let balance = moneyStore.balance {
                LabeledContent {
                    Text("\(balance.formatted()) MXN")
                        .monospacedDigit()
                } label: {
                    Text(L10n.MemberDetail.moneyBalanceLabel)
                }
            }

            LabeledContent {
                Text("\(moneyStore.obligations.count)")
                    .monospacedDigit()
            } label: {
                Text(L10n.MemberDetail.moneyObligationsLabel)
            }

            if moneyStore.obligations.isEmpty, moneyStore.balance == nil {
                Text(L10n.MemberDetail.moneyEmpty)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - History (inline preview + see-all link)

    @ViewBuilder
    private func historySection(item: MembershipBoundaryItem) -> some View {
        Section(L10n.MemberDetail.historySection) {
            switch reputationStore.phase {
            case .idle, .loading:
                ForEach(0..<3, id: \.self) { _ in
                    placeholderHistoryRow
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.Reputation.errorTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button(String(localized: L10n.Reputation.retry)) {
                        Task {
                            if let mid = item.membershipId {
                                await reputationStore.refresh(
                                    groupId: groupId,
                                    subjectMembershipId: mid
                                )
                            }
                        }
                    }
                    .font(.footnote)
                }
            case .loaded:
                if reputationStore.events.isEmpty {
                    Text(L10n.MemberDetail.historyEmpty)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(reputationStore.events.prefix(recentHistoryLimit)) { event in
                        historyRow(for: event)
                    }
                    if reputationStore.events.count > recentHistoryLimit {
                        NavigationLink(value: MemberFullHistoryDestination()) {
                            Text(L10n.MemberDetail.viewFullHistory)
                                .font(.subheadline)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func historyRow(for event: GroupReputationEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.kind.systemImageName)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.kind.label)
                    .font(.body.weight(.semibold))
                if let reason = event.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let when = event.when {
                    Text(when, format: .dateTime.day().month().year())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var placeholderHistoryRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "circle").frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text("Placeholder kind").font(.body.weight(.semibold))
                Text("Placeholder reason that takes some width.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .redacted(reason: .placeholder)
    }

    // MARK: - Activity timeline (V3 Batch B-1)

    /// Universal Detail bloque 5: eventos del feed que afectan a esta
    /// persona — entity-side (member.joined/state_changed/role.granted/
    /// role.revoked sobre la membership) + actor-side (cosas que esta
    /// persona hizo, vía actor_user_id).
    ///
    /// Invisible si el fetch falló o devolvió 0 rows (situational).
    @ViewBuilder
    private func activitySection(item: MembershipBoundaryItem) -> some View {
        if let events = activity, !events.isEmpty {
            Section("Actividad") {
                ForEach(events) { event in
                    activityRow(event: event)
                }
            }
        }
    }

    @ViewBuilder
    private func activityRow(event: GroupEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: activityIcon(for: event.eventType))
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.summary ?? event.eventType)
                    .font(.body)
                    .lineLimit(2)
                if let when = event.occurredAt {
                    Text(when, format: .dateTime.day().month().year())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Mapeo mínimo event_type → SF Symbol. Cubre los 4 event_types
    /// confirmados en data dev hoy (member.joined / state_changed /
    /// role.granted / role.revoked) + fallback genérico.
    private func activityIcon(for eventType: String) -> String {
        switch eventType {
        case "member.joined":         return "person.crop.circle.badge.plus"
        case "member.state_changed":  return "arrow.triangle.2.circlepath"
        case "role.granted":          return "person.crop.rectangle.badge.plus"
        case "role.revoked":          return "person.crop.rectangle.badge.minus"
        case let t where t.hasPrefix("money."):     return "creditcard"
        case let t where t.hasPrefix("decision."):  return "checkmark.seal"
        case let t where t.hasPrefix("sanction."):  return "exclamationmark.shield"
        case let t where t.hasPrefix("dispute."):   return "exclamationmark.bubble"
        case let t where t.hasPrefix("mandate."):   return "person.2"
        default: return "circle.fill"
        }
    }

    // MARK: - State actions (Primitiva 2)

    /// Admin actions on someone else's membership. Hidden for invites
    /// (no membership_id), for myself (uso "Leave group" en otra
    /// surface) y para estados terminales (`.left`/`.banned`).
    /// Backend gating is server-side; we surface the error via
    /// `membersStore.errorMessage`.
    @ViewBuilder
    private func stateActionsSection(item: MembershipBoundaryItem) -> some View {
        if let mid = item.membershipId,
           !item.isCurrentUser,
           item.kind == .membership
        {
            Section(L10n.MemberDetail.stateSection) {
                // V3-D.20 — Aprobar solicitud (requested → active)
                if item.status == .requested, callerPermissions.contains("members.invite") {
                    Button {
                        Task { _ = await membersStore.approveRequest(membershipId: mid, groupId: groupId) }
                    } label: {
                        Label("Aprobar solicitud", systemImage: "checkmark.circle")
                    }
                }
                // active → paused / suspended
                if item.status == .active {
                    if callerPermissions.contains("members.pause") {
                        Button {
                            membersStore.beginChangingState(membershipId: mid, target: .paused)
                        } label: {
                            Label("Pausar", systemImage: "pause.circle")
                        }
                    }
                    if callerPermissions.contains("members.suspend") {
                        Button {
                            membersStore.beginChangingState(membershipId: mid, target: .suspended)
                        } label: {
                            Label(L10n.MemberDetail.suspendAction, systemImage: "exclamationmark.octagon")
                        }
                    }
                }
                // paused → active
                if item.status == .paused, callerPermissions.contains("members.update") {
                    Button {
                        membersStore.beginChangingState(membershipId: mid, target: .active)
                    } label: {
                        Label("Reanudar", systemImage: "play.circle")
                    }
                }
                // suspended → active
                if item.status == .suspended, callerPermissions.contains("members.update") {
                    Button {
                        membersStore.beginChangingState(membershipId: mid, target: .active)
                    } label: {
                        Label(L10n.MemberDetail.reactivateAction, systemImage: "play.circle")
                    }
                }
                // removed → active (Reinstalar)
                if item.status == .removed, callerPermissions.contains("members.update") {
                    Button {
                        membersStore.beginChangingState(membershipId: mid, target: .active)
                    } label: {
                        Label("Reinstalar", systemImage: "arrow.uturn.backward.circle")
                    }
                }
                // left → active (reingreso)
                if item.status == .left, callerPermissions.contains("members.update") {
                    Button {
                        membersStore.beginChangingState(membershipId: mid, target: .active)
                    } label: {
                        Label("Reingreso", systemImage: "arrow.uturn.backward.circle")
                    }
                }
                // banned: reinstate requires decision. D.20.1 — when
                // both decisionsStore + decisionsRepository are wired AND
                // the caller has `members.update`, render the button that
                // opens an inline ProposeDecisionSheet pre-filled with
                // template_key=decision.membership_reinstate. Otherwise
                // fall back to the legacy text-only hint.
                if item.status == .banned {
                    Text(L10n.MemberDetail.reinstateHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let decisionsStore,
                       decisionsRepository != nil,
                       callerPermissions.contains("members.update") {
                        Button {
                            decisionsStore.beginProposingMembershipReinstate(membershipId: mid)
                        } label: {
                            Label(L10n.MemberDetail.reinstateAction, systemImage: "envelope.badge")
                        }
                    }
                }
                // Destructive actions: removed (reversible) + banned (hard).
                if item.status != .left, item.status != .banned, item.status != .removed,
                   callerPermissions.contains("members.remove") {
                    Button(role: .destructive) {
                        membersStore.beginChangingState(membershipId: mid, target: .removed)
                    } label: {
                        Label("Remover (reversible)", systemImage: "person.crop.circle.badge.minus")
                    }
                    Button(role: .destructive) {
                        membersStore.beginChangingState(membershipId: mid, target: .banned)
                    } label: {
                        Label(L10n.MemberDetail.removeAction, systemImage: "person.crop.circle.badge.xmark")
                    }
                }
            }
        }
    }

    /// Hashable token so the inline "Ver historial completo" row can
    /// push the dedicated `MemberHistoryView` via the destination
    /// declared on this view's NavigationStack ancestor.
    private struct MemberFullHistoryDestination: Hashable {}
}

// MARK: - Manage Roles Sheet

/// Quick-action sheet for assigning / revoking roles on a single
/// membership (Primitiva 17 / B3). Backend gates by `roles.manage`;
/// the error is surfaced inline. "Remove last role" raises a backend
/// error too — same path.
private struct ManageMemberRolesSheet: View {
    @Bindable var rolesStore: RolesStore
    @Bindable var membersStore: MembersStore
    let groupId: UUID
    let memberItem: MembershipBoundaryItem

    @Environment(\.dismiss) private var dismiss
    @State private var pendingRoleId: UUID?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                switch rolesStore.phase {
                case .idle, .loading:
                    ForEach(0..<3, id: \.self) { _ in
                        placeholderRow
                    }
                case .failed(let message):
                    ContentUnavailableView {
                        Label(L10n.Roles.errorTitle, systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button(String(localized: L10n.Roles.retry)) {
                            Task { await rolesStore.refresh(groupId: groupId) }
                        }
                    }
                    .listRowBackground(Color.clear)
                case .loaded:
                    if rolesStore.roles.isEmpty {
                        Text(L10n.MemberDetail.manageRolesEmpty)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    } else {
                        if !rolesStore.systemRoles.isEmpty {
                            Section(L10n.Roles.systemSection) {
                                ForEach(rolesStore.systemRoles) { role in
                                    row(for: role)
                                }
                            }
                        }
                        if !rolesStore.customRoles.isEmpty {
                            Section(L10n.Roles.customSection) {
                                ForEach(rolesStore.customRoles) { role in
                                    row(for: role)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.MemberDetail.manageRolesTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: L10n.MemberDetail.manageRolesDone)) {
                        dismiss()
                    }
                }
            }
            .alert(
                String(localized: L10n.MemberDetail.manageRolesErrorTitle),
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                ),
                actions: { Button("OK") { errorMessage = nil } },
                message: { Text(errorMessage ?? "") }
            )
            .task {
                await rolesStore.refreshIfNeeded(groupId: groupId)
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func row(for role: GroupRole) -> some View {
        let isAssigned = assignedRoleNames.contains(role.name)
        let isPending = pendingRoleId == role.id
        Button {
            toggle(role: role, isAssigned: isAssigned)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(role.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let description = role.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                if isPending {
                    ProgressView()
                        .controlSize(.small)
                } else if isAssigned {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(pendingRoleId != nil)
    }

    @ViewBuilder
    private var placeholderRow: some View {
        HStack {
            Text("Placeholder role").font(.body.weight(.semibold))
            Spacer()
            Image(systemName: "circle")
        }
        .redacted(reason: .placeholder)
    }

    private var assignedRoleNames: Set<String> {
        let live = membersStore.items.first(where: { $0.id == memberItem.id }) ?? memberItem
        return Set(live.roleNames)
    }

    private func toggle(role: GroupRole, isAssigned: Bool) {
        guard let mid = memberItem.membershipId, pendingRoleId == nil else { return }
        pendingRoleId = role.id
        Task {
            defer { pendingRoleId = nil }
            do {
                if isAssigned {
                    try await rolesStore.revokeRole(membershipId: mid, roleId: role.id)
                } else {
                    try await rolesStore.assignRole(membershipId: mid, roleId: role.id)
                }
                await membersStore.refresh(groupId: groupId)
                await rolesStore.refresh(groupId: groupId)
            } catch {
                errorMessage = UserFacingError.from(error).message
            }
        }
    }
}
