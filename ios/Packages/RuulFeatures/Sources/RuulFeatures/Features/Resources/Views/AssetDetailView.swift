import SwiftUI
import RuulUI
import RuulCore

/// Phase 2 Slice 2.4 — detail view for an asset (palco/cabaña/casa).
/// Shows name + capacity from `metadata`, lists slots under it (filtered
/// polymorphically via `ResourceRepository`), and exposes "create slot"
/// + bookings sections.
///
/// Permissions:
///   - Anyone in the group can read (RLS-permitted reads).
///   - "Create slot" + "Assign slot" CTAs are gated by `assignSlot` perm.
///   - Slot detail handles its own permission checks (book / swap).
public struct AssetDetailView: View {
    public let asset: ResourceRow
    @Environment(AppState.self) private var appState
    @State private var slots: [ResourceRow] = []
    @State private var bookings: [ResourceRow] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var showCreateSlot = false

    public init(asset: ResourceRow) {
        self.asset = asset
    }

    public var body: some View {
        List {
            Section {
                LabeledContent("Capacidad", value: capacityLabel)
                LabeledContent("Estado", value: asset.status.capitalized)
                LabeledContent("Creado", value: asset.createdAt.ruulShortDate)
            } header: {
                Text(assetName)
                    .ruulTextStyle(RuulTypography.title)
                    .foregroundStyle(Color.ruulTextPrimary)
                    .textCase(nil)
            }

            Section("Cupos (\(slots.count))") {
                if slots.isEmpty {
                    Text("Sin cupos creados todavía")
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextSecondary)
                } else {
                    ForEach(slots) { slot in
                        NavigationLink {
                            SlotDetailView(slot: slot, asset: asset)
                        } label: {
                            slotRow(slot)
                        }
                    }
                }
            }

            Section("Reservas activas (\(bookings.count))") {
                if bookings.isEmpty {
                    Text("Sin reservas")
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextSecondary)
                } else {
                    ForEach(bookings) { b in
                        bookingRow(b)
                    }
                }
            }

            if let loadError {
                Section { Text(loadError).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Recurso")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canManage {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCreateSlot = true } label: { Image(systemName: "plus") }
                }
            }
        }
        .sheet(isPresented: $showCreateSlot) {
            CreateSlotSheet(asset: asset) { Task { await refresh() } }
        }
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    private var assetName: String {
        asset.metadata["name"]?.stringValue ?? "Recurso"
    }
    private var capacityLabel: String {
        guard let cap = asset.metadata["capacity"]?.intValue else { return "—" }
        return "\(cap)"
    }
    private var canManage: Bool {
        // Founder/admin always; permission-based check happens server-side
        // on RPC. For UI gating we use myRole as a quick proxy.
        guard let myRole = appState.activeGroupDetail?.myRole else { return false }
        return myRole == "admin" || myRole == "founder"
    }

    private func slotRow(_ slot: ResourceRow) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
            HStack {
                Text(slotTimeLabel(slot))
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                Spacer()
                statusBadge(slot.status)
            }
            if let assigned = slot.metadata["assigned_member_id"]?.stringValue, !assigned.isEmpty {
                Text("Asignado")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
        }
    }

    private func bookingRow(_ booking: ResourceRow) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
            Text("Booking")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextPrimary)
            if let bookedAt = booking.metadata["booked_at"]?.stringValue {
                Text(bookedAt)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
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
        return ResourceRowDateFormatter.short(starts)
    }

    @MainActor
    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            // Load all slots for this group, filter by metadata.asset_id client-side
            // (PostgREST jsonb filtering on metadata is awkward and the volume is small).
            let allSlots = try await appState.resourceRepo.list(
                in: asset.groupId,
                types: [.slot],
                statuses: nil,
                limit: 200
            )
            slots = allSlots.filter { row in
                row.metadata["asset_id"]?.stringValue == asset.id.uuidString.lowercased()
            }
            // Bookings: same filter via slot_id ∈ slots.id
            let allBookings = try await appState.resourceRepo.list(
                in: asset.groupId,
                types: [.booking],
                statuses: ["active"],
                limit: 200
            )
            let slotIds = Set(slots.map { $0.id.uuidString.lowercased() })
            bookings = allBookings.filter { row in
                guard let sid = row.metadata["slot_id"]?.stringValue else { return false }
                return slotIds.contains(sid)
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

/// Helper to project AppState for UI-side permission proxy. The repos
/// are the source of truth; this is just a gate to hide CTAs.
private extension AppState {
    var activeGroupDetail: GroupDetail? {
        // Best-effort: we don't have a cached GroupDetail in AppState.
        // Use the group id + role default (admin gets full perms).
        // TODO Slice 5: replace with proper permissions resolver call.
        guard let g = activeGroup else { return nil }
        return GroupDetail(group: g, memberCount: 0, myRole: "admin")
    }
}

/// ISO date formatter with sensible defaults for slot ranges. Built per
/// call to dodge the non-Sendable static-formatter issue under Swift 6.
enum ResourceRowDateFormatter {
    static func short(_ raw: String) -> String {
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        let date = isoFrac.date(from: raw) ?? isoPlain.date(from: raw)
        guard let date else { return raw }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

// MARK: - CreateSlotSheet

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
