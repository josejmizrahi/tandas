import SwiftUI
import RuulUI
import RuulCore

/// Asset-specific inline sections rendered by `UniversalResourceDetailView`
/// when `resource.resourceType == .asset`. Replaces the legacy
/// `AssetDetailView` 7-tab SegmentedPicker — every facet now sits inline
/// in the universal frame so asset detail reads the same as fund / space /
/// event detail (one scroll, hairline-separated rows).
///
/// Four sections, each gated by a capability flag on the parent view:
///   1. `AssetCustodySection`     — who has the asset right now + checkouts (custody capability)
///   2. `AssetOwnershipSection`   — who owns it + valuation history (transfer | valuation)
///   3. `AssetMaintenanceSection` — open service items + log/report actions (maintenance)
///   4. `AssetBookingsSection`    — slot list under this asset (booking)
@MainActor
public struct AssetCustodySection: View {
    @Environment(AppState.self) private var app
    public let asset: ResourceRow
    /// Bubble called after a custody/checkout RPC mutates
    /// `resources.metadata`. The parent re-fetches the row so the
    /// custodian/holder display updates without a sheet dismiss.
    public let onMetadataChanged: () async -> Void

    @State private var members: [MemberWithProfile] = []
    @State private var showAssign: Bool = false
    @State private var showCheckout: Bool = false
    @State private var isReleasing: Bool = false
    @State private var error: String?

    public init(
        asset: ResourceRow,
        onMetadataChanged: @escaping () async -> Void = {}
    ) {
        self.asset = asset
        self.onMetadataChanged = onMetadataChanged
    }

    public var body: some View {
        RuulInfoCard("CUSTODIA") {
            if let custodian = currentCustodian {
                RuulInfoRow(label: "Custodio", value: custodian.displayName)
                if let date = asset.metadata["custody_assigned_at"]?.stringValue {
                    RuulInfoDivider()
                    RuulInfoRow(label: "Desde", value: AssetDateFormatter.short(date))
                }
            } else {
                RuulInfoRow(label: "Custodio", value: "Bajo custodia del grupo")
            }
            if let holder = currentHolder {
                RuulInfoDivider()
                RuulInfoRow(label: "Prestado a", value: holder.displayName)
                if let until = asset.metadata["expected_return_at"]?.stringValue {
                    RuulInfoDivider()
                    RuulInfoRow(label: "Devolución esperada", value: AssetDateFormatter.short(until))
                }
            }
            RuulInfoDivider()
            if currentHolder == nil {
                RuulInfoActionRow(
                    label: currentCustodian == nil ? "Asignar custodio" : "Cambiar custodio",
                    symbol: "person.badge.plus"
                ) { showAssign = true }
                RuulInfoDivider()
                RuulInfoActionRow(
                    label: "Prestar (checkout)",
                    symbol: "arrow.up.right.square"
                ) { showCheckout = true }
                if currentCustodian != nil {
                    RuulInfoDivider()
                    RuulInfoActionRow(
                        label: "Liberar custodia",
                        symbol: "person.crop.rectangle.badge.xmark",
                        isDestructive: true
                    ) {
                        Task { await releaseCustody() }
                    }
                }
            } else {
                RuulInfoActionRow(
                    label: "Marcar devuelto",
                    symbol: "arrow.down.left.square"
                ) { Task { await checkIn() } }
            }
            if let error {
                RuulInfoDivider()
                Text(error)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulNegative)
                    .padding(RuulSpacing.md)
            }
        }
        .task { await loadMembers() }
        .fullScreenCover(isPresented: $showAssign) {
            MemberPickerSheet(
                members: assignableCustodians,
                title: "Asignar custodia"
            ) { memberId in
                Task { await assignCustody(to: memberId) }
            }
        }
        .fullScreenCover(isPresented: $showCheckout) {
            CheckOutAssetSheet(asset: asset, members: members) {
                error = nil
                Task { await onMetadataChanged() }
            }
        }
    }

    private var currentCustodian: MemberWithProfile? {
        guard let raw = asset.metadata["custodian_id"]?.stringValue,
              let id = UUID(uuidString: raw) else { return nil }
        return members.first { $0.id == id }
    }

    private var currentHolder: MemberWithProfile? {
        guard let raw = asset.metadata["checked_out_to"]?.stringValue,
              let id = UUID(uuidString: raw) else { return nil }
        return members.first { $0.id == id }
    }

    /// Excludes the current custodian from the picker — selecting the
    /// same person is a no-op server-side but creates a confusing audit
    /// trail (custodyAssigned event with no actual change).
    private var assignableCustodians: [MemberWithProfile] {
        guard let current = currentCustodian else { return members }
        return members.filter { $0.id != current.id }
    }

    @MainActor
    private func loadMembers() async {
        members = (try? await app.groupsRepo.membersWithProfiles(of: asset.groupId)) ?? []
    }

    @MainActor
    private func assignCustody(to memberId: UUID) async {
        do {
            try await app.assetLifecycleRepo.assignCustody(asset: asset.id, to: memberId, notes: nil)
            error = nil
            await onMetadataChanged()
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func releaseCustody() async {
        isReleasing = true
        defer { isReleasing = false }
        do {
            try await app.assetLifecycleRepo.releaseCustody(asset: asset.id, notes: nil)
            error = nil
            await onMetadataChanged()
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func checkIn() async {
        do {
            try await app.assetLifecycleRepo.checkInAsset(asset: asset.id, conditionNotes: nil)
            error = nil
            await onMetadataChanged()
        } catch {
            self.error = error.localizedDescription
        }
    }

}

// MARK: - Ownership

@MainActor
public struct AssetOwnershipSection: View {
    @Environment(AppState.self) private var app
    public let asset: ResourceRow
    /// Bubble called after a transfer RPC mutates `resources.metadata`.
    /// Valuation also fires it (the section's own `load()` reloads the
    /// valuation row, but the parent still re-fetches the polymorphic
    /// row so INFORMACIÓN stays in sync).
    public let onMetadataChanged: () async -> Void

    @State private var members: [MemberWithProfile] = []
    @State private var latestValuation: AssetValuationRow?
    @State private var showTransfer: Bool = false
    @State private var showValuation: Bool = false
    @State private var isReleasing: Bool = false
    @State private var error: String?

    public init(
        asset: ResourceRow,
        onMetadataChanged: @escaping () async -> Void = {}
    ) {
        self.asset = asset
        self.onMetadataChanged = onMetadataChanged
    }

    public var body: some View {
        RuulInfoCard("PROPIEDAD") {
            if let owner = currentOwner {
                RuulInfoRow(label: "Dueño", value: owner.displayName)
                if let date = asset.metadata["ownership_changed_at"]?.stringValue {
                    RuulInfoDivider()
                    RuulInfoRow(label: "Desde", value: AssetDateFormatter.short(date))
                }
            } else {
                RuulInfoRow(label: "Dueño", value: "Del grupo")
            }
            if let v = latestValuation {
                RuulInfoDivider()
                RuulInfoRow(label: "Valor actual", value: AssetMoneyFormatter.format(
                    cents: v.valueCents, currency: v.currency
                ))
                RuulInfoDivider()
                RuulInfoRow(label: "Valuado", value: v.recordedAt.ruulShortDate)
            }
            RuulInfoDivider()
            RuulInfoActionRow(label: "Registrar valuación", symbol: "chart.line.uptrend.xyaxis") {
                showValuation = true
            }
            RuulInfoDivider()
            RuulInfoActionRow(label: "Transferir propiedad", symbol: "arrow.left.arrow.right") {
                showTransfer = true
            }
            if currentOwner != nil {
                RuulInfoDivider()
                RuulInfoActionRow(
                    label: "Devolver al grupo",
                    symbol: "person.3",
                    isDestructive: true
                ) {
                    Task { await transferToGroup() }
                }
            }
            if let error {
                RuulInfoDivider()
                Text(error)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulNegative)
                    .padding(RuulSpacing.md)
            }
        }
        .task { await load() }
        .fullScreenCover(isPresented: $showTransfer) {
            MemberPickerSheet(
                members: transferableMembers,
                title: "Transferir a"
            ) { memberId in
                Task { await transfer(to: memberId) }
            }
        }
        .fullScreenCover(isPresented: $showValuation) {
            RecordValuationSheet(asset: asset) {
                Task { await load() }
            }
        }
    }

    /// Excludes the current owner from the picker — transferring to
    /// the same owner is a no-op server-side but creates a confusing
    /// assetTransferred event with from == to.
    private var transferableMembers: [MemberWithProfile] {
        guard let current = currentOwner else { return members }
        return members.filter { $0.id != current.id }
    }

    private var currentOwner: MemberWithProfile? {
        guard let raw = asset.metadata["owner_id"]?.stringValue,
              let id = UUID(uuidString: raw) else { return nil }
        return members.first { $0.id == id }
    }

    @MainActor
    private func load() async {
        async let membersTask = app.groupsRepo.membersWithProfiles(of: asset.groupId)
        async let valuationTask = AssetProjectionsRepository.latestValuation(
            client: app.systemEventRepo, assetId: asset.id, groupId: asset.groupId
        )
        members = (try? await membersTask) ?? []
        latestValuation = await valuationTask
    }

    @MainActor
    private func transfer(to memberId: UUID) async {
        do {
            try await app.assetLifecycleRepo.transferAsset(asset: asset.id, to: memberId, notes: nil)
            error = nil
            await onMetadataChanged()
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func transferToGroup() async {
        isReleasing = true
        defer { isReleasing = false }
        do {
            try await app.assetLifecycleRepo.transferAsset(asset: asset.id, to: nil, notes: nil)
            error = nil
            await onMetadataChanged()
        } catch {
            self.error = error.localizedDescription
        }
    }

}

// MARK: - Maintenance

@MainActor
public struct AssetMaintenanceSection: View {
    @Environment(AppState.self) private var app
    public let asset: ResourceRow

    @State private var openItems: [SystemEvent] = []
    @State private var members: [MemberWithProfile] = []
    @State private var showLog: Bool = false
    @State private var showDamage: Bool = false
    @State private var error: String?

    public init(asset: ResourceRow) { self.asset = asset }

    public var body: some View {
        RuulInfoCard("MANTENIMIENTO") {
            RuulInfoActionRow(label: "Registrar mantenimiento", symbol: "wrench.and.screwdriver") {
                showLog = true
            }
            RuulInfoDivider()
            RuulInfoActionRow(
                label: "Reportar daño",
                symbol: "exclamationmark.triangle",
                isDestructive: true
            ) { showDamage = true }
            if openItems.isEmpty {
                RuulInfoDivider()
                RuulInfoRow(label: "Tareas abiertas", value: "0")
            } else {
                RuulInfoDivider()
                RuulInfoRow(label: "Tareas abiertas", value: "\(openItems.count)")
                ForEach(openItems, id: \.id) { item in
                    RuulInfoDivider()
                    maintenanceItem(item)
                }
            }
            if let error {
                RuulInfoDivider()
                Text(error)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulNegative)
                    .padding(RuulSpacing.md)
            }
        }
        .task { await load() }
        .fullScreenCover(isPresented: $showLog) {
            LogMaintenanceSheet(asset: asset) { Task { await load() } }
        }
        .fullScreenCover(isPresented: $showDamage) {
            ReportDamageSheet(asset: asset) { Task { await load() } }
        }
    }

    @ViewBuilder
    private func maintenanceItem(_ item: SystemEvent) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            HStack {
                Text(item.payload["kind"]?.stringValue ?? "Mantenimiento")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                Spacer()
                if let cents = costCents(of: item) {
                    Text(AssetMoneyFormatter.format(
                        cents: cents,
                        currency: item.payload["currency"]?.stringValue
                    ))
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
                }
            }
            if let notes = item.payload["notes"]?.stringValue, !notes.isEmpty {
                Text(notes)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            HStack {
                Text(item.occurredAt.ruulShortDate)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextTertiary)
                Spacer()
                Button("Cerrar") {
                    Task { await complete(item.id) }
                }
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulAccent)
            }
        }
        .padding(RuulSpacing.md)
    }

    private func costCents(of item: SystemEvent) -> Int64? {
        if case let .int(v)? = item.payload["cost_cents"] { return Int64(v) }
        if case let .double(v)? = item.payload["cost_cents"] { return Int64(v) }
        return nil
    }

    @MainActor
    private func load() async {
        do {
            members = try await app.groupsRepo.membersWithProfiles(of: asset.groupId)
            openItems = try await AssetProjectionsRepository.openMaintenance(
                repo: app.systemEventRepo, assetId: asset.id, groupId: asset.groupId
            )
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func complete(_ eventId: UUID) async {
        do {
            try await app.assetLifecycleRepo.completeMaintenance(eventId: eventId, notes: nil)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

}

// MARK: - Bookings (slots under this asset)

@MainActor
public struct AssetBookingsSection: View {
    @Environment(AppState.self) private var app
    public let asset: ResourceRow

    @State private var slots: [ResourceRow] = []
    @State private var showCreateSlot: Bool = false
    @State private var error: String?

    public init(asset: ResourceRow) { self.asset = asset }

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("CUPOS")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                Spacer()
                Button {
                    showCreateSlot = true
                } label: {
                    Label("Nuevo", systemImage: "plus")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulAccent)
                }
            }
            .padding(.horizontal, RuulSpacing.xxs)
            RuulInfoCard {
                if slots.isEmpty {
                    Text("Sin cupos. Crea uno para que los miembros reserven.")
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(RuulSpacing.md)
                } else {
                    ForEach(Array(slots.enumerated()), id: \.element.id) { idx, slot in
                        NavigationLink {
                            SlotDetailView(slot: slot, asset: asset)
                        } label: {
                            slotRow(slot)
                        }
                        .buttonStyle(.plain)
                        if idx < slots.count - 1 { RuulInfoDivider() }
                    }
                }
                if let error {
                    RuulInfoDivider()
                    Text(error)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulNegative)
                        .padding(RuulSpacing.md)
                }
            }
        }
        .task { await load() }
        .fullScreenCover(isPresented: $showCreateSlot) {
            CreateSlotSheet(asset: asset) { Task { await load() } }
        }
    }

    private func slotRow(_ slot: ResourceRow) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(slotTimeLabel(slot))
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                if let assigned = slot.metadata["assigned_member_id"]?.stringValue, !assigned.isEmpty {
                    Text("Asignado")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextTertiary)
                }
            }
            Spacer()
            statusBadge(slot.status)
            Image(systemName: "chevron.right")
                .ruulTextStyle(RuulTypography.caption)
                .foregroundStyle(Color.ruulTextTertiary)
        }
        .padding(RuulSpacing.md)
        .contentShape(Rectangle())
    }

    private func slotTimeLabel(_ slot: ResourceRow) -> String {
        guard let starts = slot.metadata["starts_at"]?.stringValue else { return "Cupo" }
        return AssetDateFormatter.short(starts)
    }

    private func statusBadge(_ status: String) -> some View {
        Text(status)
            .ruulTextStyle(RuulTypography.caption)
            .padding(.horizontal, RuulSpacing.xs)
            .padding(.vertical, 2)
            .background(Color.ruulTextTertiary.opacity(0.15))
            .foregroundStyle(Color.ruulTextSecondary)
            .clipShape(Capsule())
    }

    @MainActor
    private func load() async {
        do {
            let allSlots = try await app.resourceRepo.list(
                in: asset.groupId, types: [.slot], statuses: nil, limit: 200
            )
            slots = allSlots.filter { row in
                row.metadata["asset_id"]?.stringValue == asset.id.uuidString.lowercased()
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
