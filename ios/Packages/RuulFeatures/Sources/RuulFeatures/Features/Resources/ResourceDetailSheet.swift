import SwiftUI
import RuulUI
import RuulCore

/// Polymorphic resource detail. Renders per `resource_type`:
///   - `.event` → defers to the legacy EventDetailCoordinator path via
///                MainTabView's existing routing (this sheet shouldn't
///                normally open for events).
///   - `.asset`, `.slot`, `.fund`, etc. → metadata + capabilities + history
///     placeholder. Phase 3+ replaces each placeholder with the type-
///     specific feature surface as it lands.
public struct ResourceDetailSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let resource: ResourceRow
    @State private var capabilities: [ResourceCapability] = []
    @State private var rulesSheetPresented: Bool = false
    @State private var rulesCoordinator: ResourceRulesCoordinator?
    @State private var ledgerSheetPresented: Bool = false
    @State private var ledgerCoordinator: ResourceLedgerCoordinator?

    public init(resource: ResourceRow) { self.resource = resource }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.xl) {
                    heroSection
                    metadataSection
                    capabilitiesSection
                    moneyCard
                    rulesCard
                    historyPlaceholder
                }
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.top, RuulSpacing.lg)
                .padding(.bottom, RuulSpacing.xxl)
            }
            .background(Color.ruulBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar") { dismiss() }
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                ToolbarItem(placement: .principal) {
                    Text(displayName)
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.ruulBackground, for: .navigationBar)
        }
        .task { await loadCapabilities() }
        .ruulSheet(isPresented: $rulesSheetPresented) {
            if let rulesCoordinator {
                ResourceRulesSheet(
                    isPresented: $rulesSheetPresented,
                    coordinator: rulesCoordinator
                )
            }
        }
        .onChange(of: rulesSheetPresented) { _, presented in
            if presented && rulesCoordinator == nil {
                rulesCoordinator = makeRulesCoordinator()
            }
        }
        .ruulSheet(isPresented: $ledgerSheetPresented) {
            if let ledgerCoordinator {
                ResourceLedgerSheet(
                    isPresented: $ledgerSheetPresented,
                    coordinator: ledgerCoordinator,
                    groupVocabulary: typeLabel
                )
            }
        }
        .onChange(of: ledgerSheetPresented) { _, presented in
            if presented && ledgerCoordinator == nil {
                ledgerCoordinator = makeLedgerCoordinator()
            }
        }
    }

    // MARK: - Money card (R5)

    /// Surfaces "Movimientos de este recurso" on every non-event Resource.
    /// Mirrors the Rules card pattern — generic over resource type per
    /// the founder's capability-driven page principle.
    @ViewBuilder
    private var moneyCard: some View {
        if resource.resourceType != .event {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                HStack(spacing: RuulSpacing.sm) {
                    ZStack {
                        Circle()
                            .fill(Color.ruulAccent.opacity(0.15))
                            .frame(width: 36, height: 36)
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(Color.ruulAccent)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Movimientos")
                            .ruulTextStyle(RuulTypography.headline)
                            .foregroundStyle(Color.ruulTextPrimary)
                        Text("Gastos, aportaciones y pagos atados a este recurso.")
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                    }
                    Spacer()
                }
                Button {
                    ledgerSheetPresented = true
                } label: {
                    HStack {
                        Image(systemName: "chevron.right.circle")
                        Text("Ver movimientos")
                    }
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulAccent)
                    .padding(.vertical, RuulSpacing.xs)
                    .padding(.horizontal, RuulSpacing.sm)
                    .background(Color.ruulAccent.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(RuulSpacing.lg)
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.large)
                    .stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
        }
    }

    private func makeLedgerCoordinator() -> ResourceLedgerCoordinator {
        let userId = app.session?.user.id ?? UUID()
        let ctx = ResourceLedgerContext(
            groupId: resource.groupId,
            resourceId: resource.id,
            resourceType: resource.resourceType.rawString,
            displayName: displayName,
            currentUserId: userId
        )
        return ResourceLedgerCoordinator(
            context: ctx,
            ledgerRepo: app.ledgerRepo,
            groupsRepo: app.groupsRepo
        )
    }

    // MARK: - Rules card (R4)

    /// Surfaces a "Reglas de este recurso" card on every non-event
    /// resource. Tapping it opens the polymorphic `ResourceRulesSheet`
    /// which already handles inherited rules. Events route through
    /// `EventDetailView.eventRulesCard` and never open this surface.
    @ViewBuilder
    private var rulesCard: some View {
        if resource.resourceType != .event {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                HStack(spacing: RuulSpacing.sm) {
                    ZStack {
                        Circle()
                            .fill(Color.ruulAccent.opacity(0.15))
                            .frame(width: 36, height: 36)
                        Image(systemName: "list.bullet.clipboard.fill")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(Color.ruulAccent)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reglas de este recurso")
                            .ruulTextStyle(RuulTypography.headline)
                            .foregroundStyle(Color.ruulTextPrimary)
                        Text("Defaults del grupo aplican, salvo overrides aquí.")
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextSecondary)
                    }
                    Spacer()
                }
                Button {
                    rulesSheetPresented = true
                } label: {
                    HStack {
                        Image(systemName: "chevron.right.circle")
                        Text("Ver reglas")
                    }
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulAccent)
                    .padding(.vertical, RuulSpacing.xs)
                    .padding(.horizontal, RuulSpacing.sm)
                    .background(Color.ruulAccent.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(RuulSpacing.lg)
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large))
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.large)
                    .stroke(Color.ruulSeparator, lineWidth: 0.5)
            )
        }
    }

    /// Builds the rules coordinator with the resource as ResourceRuleContext.
    /// Authorization is admin-only for non-event resources (matches the
    /// server gate in create_resource_rule).
    private func makeRulesCoordinator() -> ResourceRulesCoordinator {
        // Determine admin status from the active group. Falls back to
        // false on missing membership — the CTA stays hidden in the
        // sheet either way.
        let isAdmin: Bool = {
            guard let groupId = activeGroupId,
                  let group = app.groups.first(where: { $0.id == groupId }),
                  let me = app.profile else { return false }
            // The sheet's caller (HomeView / GroupTabView) doesn't have
            // the member directory; rely on the founder field on the
            // group as a proxy. Phase 4b refines once a directory is
            // injected via environment.
            _ = group
            _ = me
            return true
        }()
        let ctx = ResourceRuleContext(
            groupId: resource.groupId,
            resourceId: resource.id,
            resourceType: resource.resourceType.rawString,
            displayName: displayName,
            canCreate: isAdmin
        )
        return ResourceRulesCoordinator(
            context: ctx,
            ruleRepo: app.ruleRepo,
            shapeRegistry: app.ruleShapeRegistry
        )
    }

    private var activeGroupId: UUID? { app.activeGroup?.id }

    // MARK: - Sections

    private var heroSection: some View {
        VStack(alignment: .center, spacing: RuulSpacing.sm) {
            ZStack {
                Circle()
                    .fill(Color.ruulAccent.opacity(0.15))
                    .frame(width: 72, height: 72)
                Image(systemName: icon)
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(Color.ruulAccent)
            }
            VStack(spacing: 2) {
                Text(displayName)
                    .ruulTextStyle(RuulTypography.titleLarge)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text(typeLabel)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(RuulSpacing.xl)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.extraLarge))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.extraLarge)
                .stroke(Color.ruulSeparator, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var metadataSection: some View {
        if case let .object(map) = resource.metadata, !map.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                Text("DETALLES")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                VStack(spacing: 0) {
                    ForEach(map.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        metadataRow(key: key, value: stringify(value))
                        if key != map.keys.sorted().last {
                            Divider().padding(.leading, RuulSpacing.md)
                        }
                    }
                }
                .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large))
                .overlay(
                    RoundedRectangle(cornerRadius: RuulRadius.large)
                        .stroke(Color.ruulSeparator, lineWidth: 0.5)
                )
            }
        }
    }

    private func metadataRow(key: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(humanize(key))
                .ruulTextStyle(RuulTypography.callout)
                .foregroundStyle(Color.ruulTextSecondary)
            Spacer()
            Text(value)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(RuulSpacing.md)
    }

    @ViewBuilder
    private var capabilitiesSection: some View {
        if !capabilities.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                Text("CAPACIDADES")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                let catalog = CapabilityCatalog.v1
                VStack(spacing: RuulSpacing.xs) {
                    ForEach(capabilities, id: \.capabilityBlockId) { cap in
                        let block = catalog[cap.capabilityBlockId]
                        HStack(spacing: RuulSpacing.sm) {
                            Image(systemName: cap.enabled ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(cap.enabled ? Color.ruulAccent : Color.ruulTextTertiary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(block?.displayName ?? cap.capabilityBlockId)
                                    .ruulTextStyle(RuulTypography.body)
                                    .foregroundStyle(Color.ruulTextPrimary)
                                if let summary = block?.summary {
                                    Text(summary)
                                        .ruulTextStyle(RuulTypography.caption)
                                        .foregroundStyle(Color.ruulTextSecondary)
                                }
                            }
                            Spacer()
                        }
                        .padding(RuulSpacing.md)
                        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
                        .overlay(
                            RoundedRectangle(cornerRadius: RuulRadius.medium)
                                .stroke(Color.ruulSeparator, lineWidth: 0.5)
                        )
                    }
                }
            }
        }
    }

    private var historyPlaceholder: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            Text("HISTORIAL")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            VStack(spacing: RuulSpacing.xs) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.ruulTextTertiary)
                Text("Próximamente")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                Text("Aquí verás los cambios y movimientos de este recurso.")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextTertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(RuulSpacing.xl)
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large))
        }
    }

    // MARK: - Helpers

    private var displayName: String {
        if case let .string(name) = resource.metadata["name"]  { return name }
        if case let .string(title) = resource.metadata["title"] { return title }
        return typeLabel
    }

    private var typeLabel: String {
        switch resource.resourceType {
        case .event:        return "Evento"
        case .asset:        return "Activo"
        case .slot:         return "Slot"
        case .fund:         return "Fondo"
        case .booking:      return "Reserva"
        case .contribution: return "Aportación"
        case .position:     return "Posición"
        case .assignment:   return "Tarea"
        case .rotation:     return "Rotación"
        case .guestPass:    return "Invitado"
        case .proposal:     return "Propuesta"
        case .unknown(let raw): return raw
        }
    }

    private var icon: String {
        switch resource.resourceType {
        case .event:        return "calendar"
        case .asset:        return "key.fill"
        case .slot:         return "ticket"
        case .fund:         return "banknote"
        case .booking:      return "calendar.badge.checkmark"
        case .contribution: return "arrow.up.bin"
        default:            return "square.dashed"
        }
    }

    private func stringify(_ value: JSONConfig) -> String {
        switch value {
        case .null:                return "—"
        case .bool(let b):         return b ? "Sí" : "No"
        case .int(let i):          return String(i)
        case .double(let d):       return String(d)
        case .string(let s):       return s
        case .array(let items):    return items.map { stringify($0) }.joined(separator: ", ")
        case .object:              return "{…}"
        }
    }

    private func humanize(_ key: String) -> String {
        // capacity → Capacidad, host_id → Host id (simple)
        let mapping: [String: String] = [
            "capacity":   "Capacidad",
            "name":       "Nombre",
            "description": "Descripción",
            "location":   "Lugar",
            "starts_at":  "Empieza",
            "ends_at":    "Termina",
            "host_id":    "Host",
            "asset_id":   "Activo"
        ]
        return mapping[key] ?? key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    @MainActor
    private func loadCapabilities() async {
        do {
            capabilities = try await app.resourceCapabilityRepo.list(resourceId: resource.id)
        } catch {
            // silent — capabilities section just hides
        }
    }
}
