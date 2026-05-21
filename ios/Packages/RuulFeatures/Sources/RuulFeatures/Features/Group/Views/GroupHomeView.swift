import SwiftUI
import RuulUI
import RuulCore

/// Nivel 1 home — the group as a persistent social domain.
///
/// Layout (V2 Slice 4F — Group sheet partition):
///   Always visible:
///     Hero (avatar + name + member count, slim)
///     RESUMEN (stat tiles)
///     PENDIENTES (votos abiertos + acciones, solo si hay 1+)
///     Segmented control: Personas · Cómo decidimos
///   Tab "Personas" (default):
///     IDENTIDAD (nombre/foto + invite code share)
///     PERSONAS (miembros + invitar + roles personalizados)
///     AVANZADO (rotar código + archivar + salir, destructives)
///   Tab "Cómo decidimos":
///     ACUERDOS Y GOBERNANZA (módulos + reglas vigentes + gobernanza + estilo)
///     DINERO Y ZONA (moneda + timezone)
///
/// Pre-V2-Slice-4F the Group sheet exposed 8 sections in one scroll.
/// V2 Plan §B.2 partitions them into two cognitively-coherent sub-tabs
/// so the user sees half the items at a time. Hero/summary/pendings
/// stay above the segmented control because they're high-signal and
/// shouldn't hide behind a tab selection.
///
/// Pre-V2-Slice-4F (2026-05-17 refactor) had already split the original
/// monolithic CONFIGURACIÓN + COMUNIDAD sections into 5 thematic
/// buckets — this slice preserves those buckets but groups them under
/// 2 sub-tabs so a typical user only scrolls through ~3 sections at
/// once instead of 5-6.
@MainActor
public struct GroupHomeView: View {
    @State var coordinator: GroupHomeCoordinator
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// V2 Slice 4F — Group sheet sub-tab. Defaults to `.personas` so
    /// the user sees identity / members / advanced first; switching to
    /// `.comoDecidimos` reveals rules / modules / governance / settings.
    public enum SubTab: Hashable, CaseIterable, Sendable {
        case personas
        case comoDecidimos

        public var label: String {
            switch self {
            case .personas:      return "Personas"
            case .comoDecidimos: return "Cómo decidimos"
            }
        }
    }
    @State private var subTab: SubTab = .personas

    public var onOpenMembersList: (() -> Void)?
    public var onOpenMembersAdmin: (() -> Void)?
    public let onOpenGovernance: () -> Void
    public let onOpenRulePresets: () -> Void
    /// Lista de Acuerdos vigentes (RulesView). Distinct de
    /// onOpenGovernance (que abre quién-decide-qué) y de
    /// onOpenRulePresets (que abre presets de policy).
    public var onOpenAcuerdos: (() -> Void)?
    public let onLeaveGroup: () -> Void
    public let onShareInvite: () -> Void

    public var onEditIdentity: (() -> Void)?
    public var onPickModules: (() -> Void)?
    public var onPickCurrency: (() -> Void)?
    public var onPickTimezone: (() -> Void)?
    public var onRotateCode: (() -> Void)?
    public var onInviteMembers: (() -> Void)?
    public var onConfirmLeave: (() -> Void)?
    public var onOpenRoles: (() -> Void)?
    public var onArchiveGroup: (() -> Void)?

    // Pass 2 — dashboard callbacks
    public var onOpenMyLedger: (() -> Void)?
    public var onOpenMyFines: (() -> Void)?
    public var onOpenVotes: (() -> Void)?
    public var onOpenInbox: (() -> Void)?

    public init(
        coordinator: GroupHomeCoordinator,
        onOpenMembersList: (() -> Void)? = nil,
        onOpenMembersAdmin: (() -> Void)? = nil,
        onOpenGovernance: @escaping () -> Void,
        onOpenRulePresets: @escaping () -> Void,
        onLeaveGroup: @escaping () -> Void,
        onShareInvite: @escaping () -> Void,
        onEditIdentity: (() -> Void)? = nil,
        onPickModules: (() -> Void)? = nil,
        onPickCurrency: (() -> Void)? = nil,
        onPickTimezone: (() -> Void)? = nil,
        onRotateCode: (() -> Void)? = nil,
        onInviteMembers: (() -> Void)? = nil,
        onConfirmLeave: (() -> Void)? = nil,
        onOpenRoles: (() -> Void)? = nil,
        onArchiveGroup: (() -> Void)? = nil,
        onOpenMyLedger: (() -> Void)? = nil,
        onOpenMyFines: (() -> Void)? = nil,
        onOpenVotes: (() -> Void)? = nil,
        onOpenInbox: (() -> Void)? = nil,
        onOpenAcuerdos: (() -> Void)? = nil
    ) {
        self._coordinator = State(initialValue: coordinator)
        self.onOpenMembersList = onOpenMembersList
        self.onOpenMembersAdmin = onOpenMembersAdmin
        self.onOpenGovernance = onOpenGovernance
        self.onOpenRulePresets = onOpenRulePresets
        self.onLeaveGroup = onLeaveGroup
        self.onShareInvite = onShareInvite
        self.onEditIdentity = onEditIdentity
        self.onPickModules = onPickModules
        self.onPickCurrency = onPickCurrency
        self.onPickTimezone = onPickTimezone
        self.onRotateCode = onRotateCode
        self.onInviteMembers = onInviteMembers
        self.onConfirmLeave = onConfirmLeave
        self.onOpenRoles = onOpenRoles
        self.onArchiveGroup = onArchiveGroup
        self.onOpenMyLedger = onOpenMyLedger
        self.onOpenMyFines = onOpenMyFines
        self.onOpenVotes = onOpenVotes
        self.onOpenInbox = onOpenInbox
        self.onOpenAcuerdos = onOpenAcuerdos
    }

    public var body: some View {
        ZStack {
            Color.ruulBackground.ignoresSafeArea()
            AsyncContentView(
                phase: coordinator.phase,
                onRetry: { await coordinator.refresh() },
                loaded: { _ in loadedScroll }
            )
        }
        .task { await coordinator.refresh() }
    }

    /// Body once `coordinator.group` is non-nil. Reads from `coordinator`
    /// directly (not the AsyncContentView closure value) so all the
    /// sections — which already pull from `coordinator.*` — can stay
    /// unchanged. Stale-on-error: if a refresh fails while the user is
    /// browsing, AsyncContentView keeps this view mounted and overlays
    /// an error banner instead of dumping back to a blank screen.
    private var loadedScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.xxl) {
                hero
                summarySection
                pendingsSection
                // V2 Slice 4F sub-tab chrome. Two segments only — labels
                // fit comfortably on iPhone SE width. Hero/summary/pendings
                // sit above so the high-signal stuff isn't hidden behind a
                // tab selection.
                Picker("Sección del grupo", selection: $subTab) {
                    ForEach(SubTab.allCases, id: \.self) { tab in
                        Text(tab.label).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch subTab {
                case .personas:
                    identitySection
                    peopleSection
                    advancedSection
                case .comoDecidimos:
                    rulesAndModulesSection
                    moneyAndZoneSection
                }
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.top, RuulSpacing.xs)
            .padding(.bottom, RuulSpacing.s12)
        }
        .scrollIndicators(.hidden)
        .refreshable { await coordinator.refresh() }
    }

    /// Slim hero: avatar + nombre + member count. El código de
    /// invitación se movió a la section IDENTIDAD (Apple Settings
    /// pattern) — antes hero hacía dos trabajos (identity display +
    /// invite share affordance) que cada uno merecía su lugar lógico.
    private var hero: some View {
        HStack(spacing: RuulSpacing.md) {
            RuulAvatar(
                name: coordinator.group?.name ?? "?",
                imageURL: coordinator.group?.avatarUrl.flatMap(URL.init(string:)),
                size: .large
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.group?.name ?? "—")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                Text(memberLabel)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, RuulSpacing.md)
    }

    private var memberLabel: String {
        switch coordinator.memberCount {
        case 0: "Sin miembros"
        case 1: "1 miembro"
        default: "\(coordinator.memberCount) miembros"
        }
    }

    // MARK: - Refactored sections (Apple Settings pattern)
    //
    // Antes había una sección monolítica "CONFIGURACIÓN" con 7 items
    // mezclados (identidad, moneda, timezone, módulos, reglas, presets,
    // roles) + otra "COMUNIDAD" con cosas dispares (miembros, invitar,
    // votos, acciones). UX se sentía como volcadero. Ahora split en 5
    // buckets temáticos + AVANZADO destructive separado.

    /// 1. IDENTIDAD — quién es el grupo. Nombre + foto + código de
    ///    invitación (movido del hero para unificar settings).
    private var identitySection: some View {
        sectionContainer(title: "Identidad") {
            navRow(
                icon: "pencil",
                label: "Nombre y foto",
                action: { onEditIdentity?() }
            )
            if let code = coordinator.group?.inviteCode {
                divider
                navRow(
                    icon: "link",
                    label: code,
                    trailing: {
                        Text("Compartir")
                            .font(.footnote)
                            .foregroundStyle(Color.ruulAccent)
                    },
                    action: onShareInvite
                )
            }
        }
    }

    /// 2. PERSONAS — miembros, invitar nuevos, roles personalizados.
    ///    Todo lo relacionado con humanos en este grupo.
    private var peopleSection: some View {
        sectionContainer(title: "Personas") {
            navRow(
                icon: "person.2",
                label: "Miembros",
                trailing: { trailingValue("\(coordinator.memberCount)") },
                action: {
                    coordinator.isCurrentUserAdmin
                        ? onOpenMembersAdmin?()
                        : onOpenMembersList?()
                }
            )
            if coordinator.isCurrentUserAdmin {
                divider
                navRow(
                    icon: "person.crop.circle.badge.plus",
                    label: "Invitar miembros",
                    action: { onInviteMembers?() }
                )
            }
            if coordinator.hasPermission(.assignRoles), let onOpenRoles {
                divider
                navRow(
                    icon: "person.text.rectangle",
                    label: "Roles y permisos",
                    trailing: { trailingValue("\(coordinator.group?.effectiveRoles.count ?? 2)") },
                    action: onOpenRoles
                )
            }
        }
    }

    /// 3. ACUERDOS Y GOBERNANZA — distingue dos cosas que antes se
    ///    confundían bajo "Reglas":
    ///    - Módulos activos = qué capacidades tiene el grupo
    ///    - Acuerdos vigentes = WHEN/IF/THEN concretos (RulesView)
    ///    - Gobernanza = quién puede decidir qué (GovernanceView)
    ///    - Estilo de gobernanza = preset de policy (RulePresetsView)
    private var rulesAndModulesSection: some View {
        sectionContainer(title: "Acuerdos y gobernanza") {
            navRow(
                icon: "puzzlepiece",
                label: "Módulos activos",
                trailing: { trailingValue("\(coordinator.activeModules.count)") },
                action: { onPickModules?() }
            )
            if let onOpenAcuerdos {
                divider
                navRow(
                    icon: "scroll",
                    label: "Reglas vigentes",
                    action: onOpenAcuerdos
                )
            }
            divider
            navRow(icon: "scale.3d", label: "Gobernanza", action: onOpenGovernance)
            divider
            navRow(icon: "list.bullet.clipboard", label: "Estilo de gobernanza", action: onOpenRulePresets)
        }
    }

    /// 4. DINERO Y ZONA — settings de configuración ambiente. Moneda
    ///    para todo el ledger del grupo; timezone para cron de
    ///    notificaciones + display de fechas.
    private var moneyAndZoneSection: some View {
        sectionContainer(title: "Dinero y zona") {
            navRow(
                icon: "dollarsign.circle",
                label: "Moneda",
                trailing: { trailingValue(coordinator.group?.currency ?? "—") },
                action: { onPickCurrency?() }
            )
            divider
            navRow(
                icon: "clock",
                label: "Zona horaria",
                trailing: { trailingValue(coordinator.group?.timezone ?? "—") },
                action: { onPickTimezone?() }
            )
        }
    }

    /// 5. PENDIENTES — accesos rápidos a cosas que requieren acción.
    ///    Solo se renderiza si hay 1+ pendiente; sin esto se ocultaba
    ///    detrás de COMUNIDAD y el usuario no se daba cuenta.
    @ViewBuilder
    private var pendingsSection: some View {
        let openVotes = coordinator.summary?.openVotesCount ?? 0
        let pendingActions = coordinator.summary?.pendingActionsCount ?? 0
        if openVotes > 0 || pendingActions > 0 {
            sectionContainer(title: "Pendientes") {
                if openVotes > 0 {
                    navRow(
                        icon: "hand.raised",
                        label: openVotes == 1
                            ? "1 voto abierto"
                            : "\(openVotes) votos abiertos",
                        action: { onOpenVotes?() }
                    )
                }
                if openVotes > 0 && pendingActions > 0 { divider }
                if pendingActions > 0 {
                    navRow(
                        icon: "tray.fill",
                        label: pendingActions == 1
                            ? "1 acción pendiente"
                            : "\(pendingActions) acciones pendientes",
                        action: { onOpenInbox?() }
                    )
                }
            }
        }
    }

    private var advancedSection: some View {
        sectionContainer(title: "Avanzado") {
            navRow(icon: "arrow.triangle.2.circlepath", label: "Rotar código de invitación", action: { onRotateCode?() })
            if let onArchiveGroup {
                divider
                // Archivar es soft-delete: el grupo se oculta de la lista
                // pero su historia + ledger + atoms permanecen. Útil para
                // grupos pausados o estacionales (cenas de invierno, viaje
                // que terminó). Distinct de salir — el grupo sigue siendo
                // tuyo y puedes desarchivarlo.
                navRow(
                    icon: "archivebox",
                    label: "Archivar grupo",
                    action: onArchiveGroup,
                    destructive: true
                )
            }
            divider
            navRow(
                icon: "rectangle.portrait.and.arrow.right",
                label: "Salir del grupo",
                action: { onConfirmLeave?() ?? onLeaveGroup() },
                destructive: true
            )
        }
    }

    // MARK: Summary Section

    @ViewBuilder
    private var summarySection: some View {
        if let summary = coordinator.summary {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text("Resumen")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                    .padding(.leading, RuulSpacing.xxs)
                HStack(spacing: RuulSpacing.sm) {
                    statTile(
                        value: "\(summary.memberCount)",
                        label: "Miembros",
                        action: { onOpenMembersList?() }
                    )
                    statTile(
                        value: "\(summary.upcomingEventsCount)",
                        label: "Próximos",
                        action: nil
                    )
                    statTile(
                        value: formatCurrency(summary.myBalanceCents, currency: summary.myBalanceCurrency),
                        label: "Mi balance",
                        action: onOpenMyLedger.map { cb in { cb() } }
                    )
                    if summary.pendingFinesCount > 0 {
                        statTile(
                            value: formatCurrency(summary.pendingFinesOutstandingCents, currency: summary.myBalanceCurrency),
                            label: "Multas",
                            action: onOpenMyFines.map { cb in { cb() } }
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func statTile(value: String, label: String, action: (() -> Void)?) -> some View {
        let content = VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
            Text(value)
                .font(.body.monospacedDigit().weight(.bold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RuulSpacing.md)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.lg).stroke(Color(.separator), lineWidth: 0.5)
        )

        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    private func formatCurrency(_ cents: Int64, currency: String) -> String {
        let units = Double(cents) / 100.0
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = currency
        nf.maximumFractionDigits = 0
        return nf.string(from: NSNumber(value: units)) ?? "\(currency) \(Int(units))"
    }

    // MARK: Reusable

    @ViewBuilder
    private func sectionContainer<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
                .padding(.leading, RuulSpacing.xxs)
            VStack(spacing: 0) { content() }
                .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: RuulRadius.lg)
                        .stroke(Color(.separator), lineWidth: 0.5)
                )
        }
    }

    private var divider: some View {
        Divider().background(Color(.separator)).padding(.leading, 56)
    }

    private func trailingValue(_ s: String) -> some View {
        Text(s)
            .font(.caption)
            .foregroundStyle(Color.secondary)
            .lineLimit(1)
    }

    @ViewBuilder
    private func navRow(
        icon: String,
        label: String,
        trailing: () -> some View = { EmptyView() },
        action: @escaping () -> Void,
        destructive: Bool = false
    ) -> some View {
        Button(action: action) {
            HStack(spacing: RuulSpacing.sm) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(destructive ? Color.red : Color.secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(destructive ? Color.red : Color.primary)
                Spacer()
                trailing()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color(.tertiaryLabel))
                    .accessibilityHidden(true)
            }
            .padding(RuulSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
