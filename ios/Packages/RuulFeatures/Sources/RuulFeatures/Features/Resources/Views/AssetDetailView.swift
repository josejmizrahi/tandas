import SwiftUI
import RuulUI
import RuulCore

/// Universal asset detail view — canonical asset spec §22 tabs.
///
/// `resource_type='asset'` is "objeto persistente socialmente
/// gobernable" (cars, palcos, NFTs, equity, hardware, IP, …). The
/// view organises the asset's surface into the 7 spec tabs:
///
///   - Overview      § current state
///   - Activity      § append-only atom feed
///   - Custody       § who holds it (separate from ownership)
///   - Bookings      § slot reservations under this asset
///   - Maintenance   § service/repair log
///   - Rights        § ownership + transfer
///   - Rules         § governance scoped to this resource
///
/// Each tab is a self-contained `View` with its own `task`/`refreshable`
/// — pages stay light if the user only opens Overview.
public struct AssetDetailView: View {
    public let asset: ResourceRow
    @Environment(AppState.self) private var appState
    @State private var selectedTab: Tab = .overview

    public init(asset: ResourceRow) {
        self.asset = asset
    }

    enum Tab: String, CaseIterable, Identifiable, Hashable {
        case overview     = "Overview"
        case activity     = "Activity"
        case custody      = "Custody"
        case bookings     = "Bookings"
        case maintenance  = "Maintenance"
        case rights       = "Rights"
        case rules        = "Rules"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .overview:     return "General"
            case .activity:     return "Actividad"
            case .custody:      return "Custodia"
            case .bookings:     return "Reservas"
            case .maintenance:  return "Mantenimiento"
            case .rights:       return "Propiedad"
            case .rules:        return "Reglas"
            }
        }

        var symbol: String {
            switch self {
            case .overview:     return "info.circle"
            case .activity:     return "clock.arrow.circlepath"
            case .custody:      return "person.text.rectangle"
            case .bookings:     return "calendar"
            case .maintenance:  return "wrench.and.screwdriver"
            case .rights:       return "person.crop.circle.badge.checkmark"
            case .rules:        return "list.bullet.clipboard"
            }
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Image(systemName: tab.symbol).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, RuulSpacing.s4)
            .padding(.vertical, RuulSpacing.s2)
            Divider()
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(assetName)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header (asset identity)

    private var header: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            HStack(spacing: RuulSpacing.s3) {
                Image(systemName: "key.fill")
                    .ruulTextStyle(RuulTypography.title)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(assetName)
                        .ruulTextStyle(RuulTypography.title)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Text(headerSubtitle)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, RuulSpacing.s4)
        .padding(.top, RuulSpacing.s3)
    }

    private var assetName: String {
        asset.metadata["name"]?.stringValue ?? "Activo"
    }

    private var headerSubtitle: String {
        var parts: [String] = ["Activo"]
        if asset.status != "active" {
            parts.append(asset.status.capitalized)
        }
        if asset.isArchived {
            parts.append("archivado")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Tabs

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .overview:
            AssetOverviewTab(asset: asset)
        case .activity:
            AssetActivityTab(asset: asset)
        case .custody:
            AssetCustodyTab(asset: asset)
        case .bookings:
            AssetBookingsTab(asset: asset)
        case .maintenance:
            AssetMaintenanceTab(asset: asset)
        case .rights:
            AssetRightsTab(asset: asset)
        case .rules:
            AssetRulesTab(asset: asset)
        }
    }
}

// MARK: - Overview tab

private struct AssetOverviewTab: View {
    let asset: ResourceRow
    @Environment(AppState.self) private var app
    @State private var members: [MemberWithProfile] = []
    @State private var latestValuation: AssetValuationRow?
    @State private var openMaintenance: Int = 0

    var body: some View {
        List {
            Section("Estado") {
                LabeledContent("Tipo", value: "Activo")
                LabeledContent("Estado", value: asset.status.capitalized)
                if let cap = asset.metadata["capacity"]?.intValue {
                    LabeledContent("Capacidad", value: "\(cap)")
                }
                if let unit = asset.metadata["unit_label"]?.stringValue {
                    let count = asset.metadata["currentCount"]?.intValue
                    LabeledContent("Inventario",
                        value: count.map { "\($0) \(unit)" } ?? unit)
                }
                LabeledContent("Creado", value: asset.createdAt.ruulShortDate)
            }

            Section("Custodio") {
                if let custodianId = custodianMemberId, let member = memberLookup[custodianId] {
                    LabeledContent("Quién lo tiene", value: member.displayName)
                } else {
                    Text("Sin custodio asignado — el activo está bajo custodia del grupo.")
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                if let holderId = checkedOutToId, let member = memberLookup[holderId] {
                    LabeledContent("Prestado a", value: member.displayName)
                }
            }

            if let owner = ownerMemberId, let member = memberLookup[owner] {
                Section("Propiedad") {
                    LabeledContent("Dueño", value: member.displayName)
                }
            }

            if let valuation = latestValuation {
                Section("Valor") {
                    LabeledContent("Última valuación",
                        value: AssetMoneyFormatter.format(cents: valuation.valueCents,
                                                         currency: valuation.currency))
                    LabeledContent("Registrado", value: valuation.recordedAt.ruulShortDate)
                }
            }

            if openMaintenance > 0 {
                Section("Mantenimiento") {
                    Label("\(openMaintenance) tarea\(openMaintenance == 1 ? "" : "s") abierta\(openMaintenance == 1 ? "" : "s")", systemImage: "wrench.and.screwdriver")
                        .foregroundStyle(.orange)
                }
            }
        }
        .task { await loadAll() }
        .refreshable { await loadAll() }
    }

    private var memberLookup: [UUID: MemberWithProfile] {
        Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
    }

    private var custodianMemberId: UUID? {
        asset.metadata["custodian_id"]?.stringValue.flatMap(UUID.init(uuidString:))
    }
    private var ownerMemberId: UUID? {
        asset.metadata["owner_id"]?.stringValue.flatMap(UUID.init(uuidString:))
    }
    private var checkedOutToId: UUID? {
        asset.metadata["checked_out_to"]?.stringValue.flatMap(UUID.init(uuidString:))
    }

    @MainActor
    private func loadAll() async {
        async let m: [MemberWithProfile] = (try? await app.groupsRepo.membersWithProfiles(of: asset.groupId)) ?? []
        async let v = AssetProjectionsRepository.latestValuation(client: app.systemEventRepo, assetId: asset.id, groupId: asset.groupId)
        async let mc = AssetProjectionsRepository.openMaintenanceCount(repo: app.systemEventRepo, assetId: asset.id, groupId: asset.groupId)
        members = await m
        latestValuation = await v
        openMaintenance = await mc
    }
}

// MARK: - Activity tab

private struct AssetActivityTab: View {
    let asset: ResourceRow
    @Environment(AppState.self) private var app
    @State private var events: [SystemEvent] = []
    @State private var members: [MemberWithProfile] = []
    @State private var error: String?

    var body: some View {
        List {
            if events.isEmpty {
                Text("Sin actividad todavía. Cuando alguien use, custodie, repare o valore este activo aparecerá aquí.")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            ForEach(events, id: \.id) { event in
                let memberName = event.memberId.flatMap { id in members.first { $0.id == id } }?.displayName
                let p = HistoryItemPresentation(event: event, memberName: memberName)
                HStack(alignment: .top, spacing: RuulSpacing.s3) {
                    Image(systemName: p.icon)
                        .frame(width: 24)
                        .foregroundStyle(toneColor(p.tone))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.title).ruulTextStyle(RuulTypography.body)
                        Text(p.timestamp).ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulTextTertiary)
                    }
                }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func toneColor(_ tone: RuulTimelineItem.Tone) -> Color {
        switch tone {
        case .positive: return .green
        case .negative: return .red
        case .warning:  return .orange
        case .info:     return .blue
        case .neutral:  return Color.ruulTextSecondary
        }
    }

    @MainActor
    private func load() async {
        do {
            members = try await app.groupsRepo.membersWithProfiles(of: asset.groupId)
            events = try await app.systemEventRepo.query(
                filter: SystemEventFilter(groupId: asset.groupId, resourceId: asset.id),
                limit: 200, offset: 0
            )
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Custody tab

private struct AssetCustodyTab: View {
    let asset: ResourceRow
    @Environment(AppState.self) private var app
    @State private var members: [MemberWithProfile] = []
    @State private var showAssignSheet = false
    @State private var isReleasing = false
    @State private var error: String?

    var body: some View {
        List {
            Section("Estado actual") {
                if let custodian = currentCustodian {
                    LabeledContent("Custodio", value: custodian.displayName)
                    if let date = asset.metadata["custody_assigned_at"]?.stringValue {
                        LabeledContent("Desde", value: AssetDateFormatter.short(date))
                    }
                } else {
                    Text("Sin custodio individual — el activo está bajo custodia del grupo.")
                        .foregroundStyle(Color.ruulTextSecondary)
                }
            }

            Section("Acciones") {
                Button {
                    showAssignSheet = true
                } label: {
                    Label(currentCustodian == nil ? "Asignar custodio" : "Cambiar custodio",
                          systemImage: "person.badge.plus")
                }
                if currentCustodian != nil {
                    Button(role: .destructive) {
                        Task { await releaseCustody() }
                    } label: {
                        Label("Liberar custodia", systemImage: "person.crop.rectangle.badge.xmark")
                    }
                    .disabled(isReleasing)
                }
            }

            Section {
                Text("La custodia es operacional: quién físicamente tiene el activo. Es independiente de la propiedad (ver Propiedad).")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .task { await loadMembers() }
        .sheet(isPresented: $showAssignSheet) {
            MemberPickerSheet(members: members, title: "Asignar custodia") { memberId in
                Task { await assignCustody(to: memberId) }
            }
        }
    }

    private var currentCustodian: MemberWithProfile? {
        guard let raw = asset.metadata["custodian_id"]?.stringValue,
              let id = UUID(uuidString: raw) else { return nil }
        return members.first { $0.id == id }
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
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Bookings tab (slots/bookings under this asset)

private struct AssetBookingsTab: View {
    let asset: ResourceRow
    @Environment(AppState.self) private var app
    @State private var slots: [ResourceRow] = []
    @State private var error: String?
    @State private var showCreateSlot = false

    var body: some View {
        List {
            Section("Cupos (\(slots.count))") {
                if slots.isEmpty {
                    Text("Sin cupos creados todavía. Crea uno para que los miembros puedan reservar.")
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                ForEach(slots) { slot in
                    NavigationLink {
                        SlotDetailView(slot: slot, asset: asset)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(slotTimeLabel(slot)).ruulTextStyle(RuulTypography.body)
                                if let assigned = slot.metadata["assigned_member_id"]?.stringValue, !assigned.isEmpty {
                                    Text("Asignado").ruulTextStyle(RuulTypography.caption)
                                        .foregroundStyle(Color.ruulTextTertiary)
                                }
                            }
                            Spacer()
                            statusBadge(slot.status)
                        }
                    }
                }
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCreateSlot = true } label: { Image(systemName: "plus") }
            }
        }
        .fullScreenCover(isPresented: $showCreateSlot) {
            CreateSlotSheet(asset: asset) { Task { await load() } }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    @MainActor
    private func load() async {
        do {
            let allSlots = try await app.resourceRepo.list(in: asset.groupId, types: [.slot], statuses: nil, limit: 200)
            slots = allSlots.filter { row in
                row.metadata["asset_id"]?.stringValue == asset.id.uuidString.lowercased()
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func statusBadge(_ status: String) -> some View {
        Text(status)
            .ruulTextStyle(RuulTypography.caption)
            .padding(.horizontal, RuulSpacing.xs)
            .padding(.vertical, 2)
            .background(badgeColor(for: status).opacity(0.15))
            .foregroundStyle(badgeColor(for: status))
            .clipShape(Capsule())
    }

    private func badgeColor(for status: String) -> Color {
        switch status {
        case "unassigned": return .gray
        case "assigned":   return .blue
        case "booked":     return .green
        case "expired":    return .red
        default:           return .secondary
        }
    }

    private func slotTimeLabel(_ slot: ResourceRow) -> String {
        guard let starts = slot.metadata["starts_at"]?.stringValue else { return "Cupo" }
        return AssetDateFormatter.short(starts)
    }
}

// MARK: - Maintenance tab

private struct AssetMaintenanceTab: View {
    let asset: ResourceRow
    @Environment(AppState.self) private var app
    @State private var openItems: [SystemEvent] = []
    @State private var members: [MemberWithProfile] = []
    @State private var showLogSheet = false
    @State private var showDamageSheet = false
    @State private var error: String?

    var body: some View {
        List {
            Section("Acciones") {
                Button {
                    showLogSheet = true
                } label: {
                    Label("Registrar mantenimiento", systemImage: "wrench.and.screwdriver")
                }
                Button(role: .destructive) {
                    showDamageSheet = true
                } label: {
                    Label("Reportar daño", systemImage: "exclamationmark.triangle")
                }
            }

            Section("Tareas abiertas (\(openItems.count))") {
                if openItems.isEmpty {
                    Text("Sin mantenimiento pendiente.")
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                ForEach(openItems, id: \.id) { item in
                    MaintenanceItemRow(item: item, members: members) {
                        Task { await complete(item.id) }
                    }
                }
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showLogSheet) {
            LogMaintenanceSheet(asset: asset) { Task { await load() } }
        }
        .sheet(isPresented: $showDamageSheet) {
            ReportDamageSheet(asset: asset) { Task { await load() } }
        }
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

private struct MaintenanceItemRow: View {
    let item: SystemEvent
    let members: [MemberWithProfile]
    let onComplete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            HStack {
                Text(kindLabel)
                    .ruulTextStyle(RuulTypography.body)
                Spacer()
                if let cents = costCents {
                    Text(AssetMoneyFormatter.format(cents: cents, currency: currency))
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
            }
            if let notes, !notes.isEmpty {
                Text(notes)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            HStack {
                Text(item.occurredAt.ruulShortDate)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextTertiary)
                Spacer()
                Button("Cerrar", action: onComplete)
                    .buttonStyle(.borderless)
                    .ruulTextStyle(RuulTypography.caption)
            }
        }
    }

    private var kindLabel: String {
        item.payload["kind"]?.stringValue ?? "Mantenimiento"
    }
    private var notes: String? { item.payload["notes"]?.stringValue }
    private var costCents: Int64? {
        if case let .int(v)? = item.payload["cost_cents"] { return Int64(v) }
        if case let .double(v)? = item.payload["cost_cents"] { return Int64(v) }
        return nil
    }
    private var currency: String? { item.payload["currency"]?.stringValue }
}

// MARK: - Rights tab (ownership + transfer)

private struct AssetRightsTab: View {
    let asset: ResourceRow
    @Environment(AppState.self) private var app
    @State private var members: [MemberWithProfile] = []
    @State private var showTransferSheet = false
    @State private var isReleasing = false
    @State private var error: String?

    var body: some View {
        List {
            Section("Propiedad actual") {
                if let owner = currentOwner {
                    LabeledContent("Dueño", value: owner.displayName)
                    if let date = asset.metadata["ownership_changed_at"]?.stringValue {
                        LabeledContent("Desde", value: AssetDateFormatter.short(date))
                    }
                } else {
                    Text("El activo es del grupo (sin dueño individual).")
                        .foregroundStyle(Color.ruulTextSecondary)
                }
            }

            Section("Acciones") {
                Button {
                    showTransferSheet = true
                } label: {
                    Label("Transferir propiedad", systemImage: "arrow.left.arrow.right")
                }
                if currentOwner != nil {
                    Button(role: .destructive) {
                        Task { await transferToGroup() }
                    } label: {
                        Label("Devolver al grupo", systemImage: "person.3")
                    }
                    .disabled(isReleasing)
                }
            }

            Section {
                Text("La propiedad es el claim social/legal. Es independiente de la custodia (quién lo tiene físicamente).")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .task { await loadMembers() }
        .sheet(isPresented: $showTransferSheet) {
            MemberPickerSheet(members: members, title: "Transferir a") { memberId in
                Task { await transfer(to: memberId) }
            }
        }
    }

    private var currentOwner: MemberWithProfile? {
        guard let raw = asset.metadata["owner_id"]?.stringValue,
              let id = UUID(uuidString: raw) else { return nil }
        return members.first { $0.id == id }
    }

    @MainActor
    private func loadMembers() async {
        members = (try? await app.groupsRepo.membersWithProfiles(of: asset.groupId)) ?? []
    }

    @MainActor
    private func transfer(to memberId: UUID) async {
        do {
            try await app.assetLifecycleRepo.transferAsset(asset: asset.id, to: memberId, notes: nil)
            error = nil
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
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Rules tab (placeholder — wired into existing rules UI)

private struct AssetRulesTab: View {
    let asset: ResourceRow

    var body: some View {
        List {
            Section {
                Text("Las reglas del activo se configuran desde la pestaña de Reglas del grupo, con scope=\"recurso\" apuntando a este activo.")
                    .foregroundStyle(Color.ruulTextSecondary)
            }
            Section("Recordatorio") {
                Text("Ejemplos típicos:")
                Text("• Si daño > $5,000 → requiere voto.")
                Text("• Si maintenance overdue → bloquea reserva.")
                Text("• Si no se devuelve → multa.")
            }
        }
    }
}

// MARK: - Helpers (private)

private struct MemberPickerSheet: View {
    let members: [MemberWithProfile]
    let title: String
    let onSelect: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(members) { m in
                Button {
                    onSelect(m.id)
                    dismiss()
                } label: {
                    HStack {
                        Text(m.displayName)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(Color.ruulTextTertiary)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
    }
}

private struct LogMaintenanceSheet: View {
    let asset: ResourceRow
    let onSubmitted: () -> Void
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var kind: String = ""
    @State private var notes: String = ""
    @State private var costString: String = ""
    @State private var isSubmitting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Tipo de mantenimiento") {
                    TextField("Service / Inspección / Reparación", text: $kind)
                }
                Section("Notas") {
                    TextField("Detalles", text: $notes, axis: .vertical)
                }
                Section("Costo (opcional)") {
                    TextField("0", text: $costString)
                        .keyboardType(.decimalPad)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Registrar mantenimiento")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Guardar") { Task { await submit() } }
                        .disabled(isSubmitting || kind.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    @MainActor
    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let cents: Int64? = {
            let trimmed = costString.trimmingCharacters(in: .whitespaces)
            guard let value = Double(trimmed.replacingOccurrences(of: ",", with: ".")) else { return nil }
            return Int64(value * 100)
        }()
        do {
            _ = try await app.assetLifecycleRepo.logMaintenance(
                asset: asset.id,
                kind: kind,
                notes: notes.isEmpty ? nil : notes,
                costCents: cents,
                currency: nil
            )
            onSubmitted()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ReportDamageSheet: View {
    let asset: ResourceRow
    let onSubmitted: () -> Void
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var severity: AssetDamageSeverity = .minor
    @State private var notes: String = ""
    @State private var costString: String = ""
    @State private var isSubmitting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Severidad") {
                    Picker("", selection: $severity) {
                        ForEach(AssetDamageSeverity.allCases, id: \.self) { s in
                            Text(s.label).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Notas") {
                    TextField("Qué pasó", text: $notes, axis: .vertical)
                }
                Section("Costo estimado (opcional)") {
                    TextField("0", text: $costString)
                        .keyboardType(.decimalPad)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Reportar daño")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Reportar") { Task { await submit() } }
                        .disabled(isSubmitting)
                }
            }
        }
    }

    @MainActor
    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let cents: Int64? = {
            let trimmed = costString.trimmingCharacters(in: .whitespaces)
            guard let value = Double(trimmed.replacingOccurrences(of: ",", with: ".")) else { return nil }
            return Int64(value * 100)
        }()
        do {
            _ = try await app.assetLifecycleRepo.reportDamage(
                asset: asset.id,
                severity: severity,
                notes: notes.isEmpty ? nil : notes,
                estimatedCostCents: cents,
                currency: nil
            )
            onSubmitted()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - CreateSlotSheet (preserved from previous detail view)

private struct CreateSlotSheet: View {
    let asset: ResourceRow
    let onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @State private var startsAt = Date().addingTimeInterval(86400)
    @State private var endsAt   = Date().addingTimeInterval(86400 + 3 * 3600)
    @State private var isSubmitting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Inicio") { DatePicker("Empieza", selection: $startsAt) }
                Section("Fin")    { DatePicker("Termina", selection: $endsAt) }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Nuevo cupo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Crear") { Task { await submit() } }
                        .disabled(isSubmitting || endsAt <= startsAt)
                }
            }
        }
    }

    @MainActor
    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            _ = try await appState.slotLifecycleRepo.createSlot(
                asset: asset.id,
                startsAt: startsAt,
                endsAt: endsAt
            )
            onCreated()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Date / money formatters

enum AssetDateFormatter {
    static func short(_ raw: String) -> String {
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        let date = isoFrac.date(from: raw) ?? isoPlain.date(from: raw)
        guard let date else { return raw }
        return date.ruulMediumDateTime
    }
}

enum AssetMoneyFormatter {
    static func format(cents: Int64?, currency: String?) -> String {
        guard let cents else { return "—" }
        let amount = Double(cents) / 100.0
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency ?? "MXN"
        f.locale = Locale(identifier: "es_MX")
        return f.string(from: NSNumber(value: amount)) ?? "\(amount)"
    }
}

// MARK: - Asset projections (read-side helpers)

/// Lightweight wrapper around the asset_*_view projections (mig 00201).
/// Reads are issued via the existing systemEventRepo for now —
/// `asset_valuation_view` and `asset_maintenance_status_view` collapse
/// to filtered queries over `system_events` so the same repository
/// supports them without a dedicated PostgREST model.
struct AssetValuationRow {
    let valueCents: Int64
    let currency: String?
    let recordedAt: Date
}

enum AssetProjectionsRepository {
    static func latestValuation(client: any SystemEventRepository, assetId: UUID, groupId: UUID) async -> AssetValuationRow? {
        guard let events = try? await client.query(
            filter: SystemEventFilter(groupId: groupId, eventType: .valuationRecorded, resourceId: assetId),
            limit: 1, offset: 0
        ) else {
            return nil
        }
        let valuations = events
            .filter { $0.eventType == .valuationRecorded }
            .sorted { $0.occurredAt > $1.occurredAt }
        guard let latest = valuations.first else { return nil }
        let cents: Int64? = {
            if case let .int(v)? = latest.payload["value_cents"] { return Int64(v) }
            if case let .double(v)? = latest.payload["value_cents"] { return Int64(v) }
            return nil
        }()
        guard let c = cents else { return nil }
        return AssetValuationRow(
            valueCents: c,
            currency: latest.payload["currency"]?.stringValue,
            recordedAt: latest.occurredAt
        )
    }

    /// Open maintenance items = `maintenanceLogged` events for which
    /// no `maintenanceCompleted` event references their id.
    static func openMaintenance(repo: any SystemEventRepository, assetId: UUID, groupId: UUID) async throws -> [SystemEvent] {
        let events = try await repo.query(
            filter: SystemEventFilter(groupId: groupId, resourceId: assetId),
            limit: 200, offset: 0
        )
        let logged = events.filter { $0.eventType == .maintenanceLogged }
        let completedIds: Set<UUID> = Set(
            events
                .filter { $0.eventType == .maintenanceCompleted }
                .compactMap { e -> UUID? in
                    guard let raw = e.payload["maintenance_event_id"]?.stringValue else { return nil }
                    return UUID(uuidString: raw)
                }
        )
        return logged
            .filter { !completedIds.contains($0.id) }
            .sorted { $0.occurredAt > $1.occurredAt }
    }

    static func openMaintenanceCount(repo: any SystemEventRepository, assetId: UUID, groupId: UUID) async -> Int {
        (try? await openMaintenance(repo: repo, assetId: assetId, groupId: groupId).count) ?? 0
    }
}
