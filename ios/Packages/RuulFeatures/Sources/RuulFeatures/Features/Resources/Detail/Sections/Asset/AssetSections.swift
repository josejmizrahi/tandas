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
///   1. `AssetCustodySection`     — who has the asset right now (read-only display)
///   2. `AssetOwnershipSection`   — who owns it + valuation history (read-only display)
///   3. `AssetMaintenanceSection` — open service items (read-only display + close items)
///   4. `AssetBookingsSection`    — slot list under this asset (read-only display)
///
/// Per doctrine 2026-05-18: all action verbs live in the resource detail
/// toolbar `+` menu (`ResourceIntentRegistry`). Sections are pure
/// information cards — no buttons, no sheets, no RPC dispatch.
@MainActor
public struct AssetCustodySection: View {
    @Environment(AppState.self) private var app
    public let asset: ResourceRow
    /// Kept for API stability — sections no longer mutate the resource
    /// (the toolbar does). The bubble is a no-op for now; remove when
    /// no caller passes it.
    public let onMetadataChanged: () async -> Void

    @State private var members: [MemberWithProfile] = []

    public init(
        asset: ResourceRow,
        onMetadataChanged: @escaping () async -> Void = {}
    ) {
        self.asset = asset
        self.onMetadataChanged = onMetadataChanged
    }

    /// Catalog registration — asset-only via isVisibleFor, gated on the
    /// `custody` capability. Per UniversalRuleTemplates §14 catalog
    /// migration (fase 2).
    public static let definition = CapabilitySection(
        id: "asset.custody",
        priority: 160,
        tabId: "people",
        isEnabledFor: { caps in caps.contains(CapabilityID.custody) },
        isVisibleFor: { ctx in ctx.resource.resourceType == .asset },
        render: { ctx in AnyView(AssetCustodySection(
            asset: ctx.resource,
            onMetadataChanged: { await ctx.onResourceMutated() }
        )) }
    )

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
        }
        .task { await loadMembers() }
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

    @MainActor
    private func loadMembers() async {
        members = (try? await app.groupsRepo.membersWithProfiles(of: asset.groupId)) ?? []
    }
}

// MARK: - Ownership

@MainActor
public struct AssetOwnershipSection: View {
    @Environment(AppState.self) private var app
    public let asset: ResourceRow
    /// Kept for API stability — sections are read-only post-doctrine.
    public let onMetadataChanged: () async -> Void

    @State private var members: [MemberWithProfile] = []
    @State private var latestValuation: AssetValuationRow?

    public init(
        asset: ResourceRow,
        onMetadataChanged: @escaping () async -> Void = {}
    ) {
        self.asset = asset
        self.onMetadataChanged = onMetadataChanged
    }

    /// Catalog registration — asset-only, enabled when either `transfer`
    /// OR `valuation` is on (mirrors the inline OR gate that was in the
    /// view's body pre-mig).
    public static let definition = CapabilitySection(
        id: "asset.ownership",
        priority: 161,
        tabId: "people",
        isEnabledFor: { caps in caps.contains(CapabilityID.transfer) || caps.contains(CapabilityID.valuation) },
        isVisibleFor: { ctx in ctx.resource.resourceType == .asset },
        render: { ctx in AnyView(AssetOwnershipSection(
            asset: ctx.resource,
            onMetadataChanged: { await ctx.onResourceMutated() }
        )) }
    )

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
        }
        .task { await load() }
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
}

// MARK: - Maintenance

@MainActor
public struct AssetMaintenanceSection: View {
    @Environment(AppState.self) private var app
    public let asset: ResourceRow

    @State private var openItems: [SystemEvent] = []
    @State private var members: [MemberWithProfile] = []
    @State private var error: String?

    public init(asset: ResourceRow) { self.asset = asset }

    /// Catalog registration — asset-only via isVisibleFor, gated on the
    /// `maintenance` capability. Maintenance writes system_events (not
    /// resources.metadata), so it doesn't need an onMetadataChanged
    /// callback — the section's internal reload handles freshness.
    public static let definition = CapabilitySection(
        id: "asset.maintenance",
        priority: 162,
        isEnabledFor: { caps in caps.contains(CapabilityID.maintenance) },
        isVisibleFor: { ctx in ctx.resource.resourceType == .asset },
        render: { ctx in AnyView(AssetMaintenanceSection(asset: ctx.resource)) }
    )

    public var body: some View {
        RuulInfoCard("MANTENIMIENTO") {
            if openItems.isEmpty {
                RuulInfoRow(label: "Tareas abiertas", value: "0")
            } else {
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
    @State private var error: String?

    public init(asset: ResourceRow) { self.asset = asset }

    /// Catalog registration — asset-only via isVisibleFor, gated on the
    /// `booking` capability. The stub `booking` section (Sections/Stubs/)
    /// also gates on `booking`; the asset-specific renderer wins for
    /// asset resources via the type predicate, and the stub is filtered
    /// out for assets in the view's stub-render filter.
    public static let definition = CapabilitySection(
        id: "asset.bookings",
        priority: 163,
        isEnabledFor: { caps in caps.contains(CapabilityID.booking) },
        isVisibleFor: { ctx in ctx.resource.resourceType == .asset },
        render: { ctx in AnyView(AssetBookingsSection(asset: ctx.resource)) }
    )

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("CUPOS")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.horizontal, RuulSpacing.xxs)
            RuulInfoCard {
                if slots.isEmpty {
                    Text("Sin cupos. Usa “+” → Crear cupo para agregar uno.")
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

// MARK: - INFORMACIÓN rows

/// Asset-specific INFORMACIÓN rows. Extracted from
/// `UniversalResourceDetailView.typeSpecificRows` per ontology
/// constitution Rule 6. Registered with `ResourceInfoRegistry` at boot.
@MainActor
public enum AssetInfoProvider {
    public static func rows(for ctx: ResourceDetailContext) -> [ResourceInfoRow] {
        // Owner / custodian / borrower already live in dedicated
        // sections (PROPIEDAD / CUSTODIA) two rows below. Repeating
        // them here duplicated the info — INFORMACIÓN only holds
        // facts the section list won't surface elsewhere.
        var out: [ResourceInfoRow] = []
        if let cap = ctx.resource.metadata["capacity"]?.intValue {
            out.append(ResourceInfoRow(label: "Capacidad", value: "\(cap)"))
        }
        if let unit = ctx.resource.metadata["unit_label"]?.stringValue {
            let count = ctx.resource.metadata["currentCount"]?.intValue
            out.append(ResourceInfoRow(label: "Inventario", value: count.map { "\($0) \(unit)" } ?? unit))
        }
        return out
    }

    private static func uuidFromMeta(_ ctx: ResourceDetailContext, _ key: String) -> UUID? {
        guard let raw = ctx.resource.metadata[key]?.stringValue, !raw.isEmpty else { return nil }
        return UUID(uuidString: raw)
    }

    /// Asset metadata stores group_members.id (NOT user id), so a direct
    /// memberDirectory subscript misses. memberDirectory is keyed by
    /// userId for events; iterate values to find by member.id.
    private static func memberByMemberId(_ ctx: ResourceDetailContext, id: UUID) -> MemberWithProfile? {
        ctx.memberDirectory.values.first { $0.member.id == id }
    }
}
