import SwiftUI
import RuulUI
import RuulCore

// MARK: - Date / money formatters

/// ISO-8601 → short date string. Handles both fractional and plain
/// shapes the backend may emit (some dual-write paths include fractional
/// seconds, some don't).
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

// MARK: - Projections (read-side helpers)

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

// MARK: - Sheets

struct MemberPickerSheet: View {
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
                            .foregroundStyle(Color(.tertiaryLabel))
                    }
                }
            }
            .ruulSheetToolbar(title)
        }
    }
}

struct LogMaintenanceSheet: View {
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
            .ruulSheetToolbar("Registrar mantenimiento")
            .toolbar {
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

struct ReportDamageSheet: View {
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
            .ruulSheetToolbar("Reportar daño")
            .toolbar {
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

struct CheckOutAssetSheet: View {
    let asset: ResourceRow
    let members: [MemberWithProfile]
    let onSubmitted: () -> Void
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var selectedMemberId: UUID?
    @State private var hasReturnDate: Bool = true
    @State private var expectedReturnAt: Date = .now.addingTimeInterval(7 * 86400)
    @State private var notes: String = ""
    @State private var isSubmitting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Prestar a") {
                    Picker("Miembro", selection: $selectedMemberId) {
                        Text("Yo mismo").tag(UUID?.none)
                        ForEach(members) { m in
                            Text(m.displayName).tag(UUID?.some(m.id))
                        }
                    }
                }
                Section("Devolución esperada") {
                    Toggle("Fijar fecha", isOn: $hasReturnDate)
                    if hasReturnDate {
                        DatePicker("Devolver antes de", selection: $expectedReturnAt)
                    }
                }
                Section("Notas (opcional)") {
                    TextField("Detalles", text: $notes, axis: .vertical)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .ruulSheetToolbar("Prestar activo")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Prestar") { Task { await submit() } }
                        .disabled(isSubmitting)
                }
            }
        }
    }

    @MainActor
    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            _ = try await app.assetLifecycleRepo.checkOutAsset(
                asset: asset.id,
                to: selectedMemberId,
                expectedReturnAt: hasReturnDate ? expectedReturnAt : nil,
                notes: notes.isEmpty ? nil : notes
            )
            onSubmitted()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct RecordValuationSheet: View {
    let asset: ResourceRow
    let onSubmitted: () -> Void
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var amountString: String = ""
    @State private var currency: String = "MXN"
    @State private var source: String = ""
    @State private var notes: String = ""
    @State private var isSubmitting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Valor estimado") {
                    TextField("0", text: $amountString)
                        .keyboardType(.decimalPad)
                }
                Section("Moneda") {
                    Picker("Moneda", selection: $currency) {
                        Text("MXN").tag("MXN")
                        Text("USD").tag("USD")
                        Text("EUR").tag("EUR")
                    }
                }
                Section("Fuente (opcional)") {
                    TextField("ej: appraisal, market, gut feel", text: $source)
                }
                Section("Notas (opcional)") {
                    TextField("Detalles", text: $notes, axis: .vertical)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .ruulSheetToolbar("Registrar valuación")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Guardar") { Task { await submit() } }
                        .disabled(isSubmitting || parsedCents == nil)
                }
            }
        }
    }

    private var parsedCents: Int64? {
        let trimmed = amountString.trimmingCharacters(in: .whitespaces)
        guard let value = Double(trimmed.replacingOccurrences(of: ",", with: ".")) else { return nil }
        guard value >= 0 else { return nil }
        return Int64(value * 100)
    }

    @MainActor
    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        guard let cents = parsedCents else {
            error = "Monto inválido"
            return
        }
        do {
            _ = try await app.assetLifecycleRepo.recordValuation(
                asset: asset.id,
                valueCents: cents,
                currency: currency,
                source: source.isEmpty ? nil : source,
                notes: notes.isEmpty ? nil : notes
            )
            onSubmitted()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct CreateSlotSheet: View {
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
            .ruulSheetToolbar("Nuevo cupo")
            .toolbar {
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
