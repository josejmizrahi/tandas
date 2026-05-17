import SwiftUI
import RuulUI
import RuulCore

/// Phase 2 Slice 2.4 — detail view for a slot (one cupo of an asset).
/// Shows time range, status, assigned holder, booking, and exposes
/// 3 actions: Assign (founder/admin), Book (any member with bookSlot),
/// Request swap (current assigned holder).
public struct SlotDetailView: View {
    public let slot: ResourceRow
    public let asset: ResourceRow
    @Environment(AppState.self) private var appState
    @State private var members: [MemberWithProfile] = []
    @State private var showAssignSheet = false
    @State private var showSwapSheet = false
    @State private var isBooking = false
    @State private var actionError: String?
    @State private var actionInfo: String?

    public init(slot: ResourceRow, asset: ResourceRow) {
        self.slot = slot
        self.asset = asset
    }

    public var body: some View {
        List {
            Section {
                LabeledContent("Empieza", value: rangeLabel(key: "starts_at"))
                LabeledContent("Termina", value: rangeLabel(key: "ends_at"))
                LabeledContent("Estado", value: slot.status.capitalized)
                LabeledContent("Recurso", value: assetName)
            } header: {
                Text("Cupo")
                    .ruulTextStyle(RuulTypography.title)
                    .textCase(nil)
            }

            Section("Asignación") {
                if let assigned = assignedMember {
                    LabeledContent("Titular", value: assigned.displayName)
                } else {
                    Text("Sin titular")
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                if let booking = bookingId {
                    LabeledContent("Reserva", value: booking.uuidString.prefix(8) + "…")
                }
            }

            Section("Acciones") {
                if canAssign {
                    Button("Asignar a un miembro") { showAssignSheet = true }
                }
                if canBook {
                    Button("Reservar este cupo", action: { Task { await book() } })
                        .disabled(isBooking)
                }
                if canRequestSwap {
                    Button("Solicitar swap a otro miembro") { showSwapSheet = true }
                }
            }

            if let actionError {
                Section { Text(actionError).foregroundStyle(.red) }
            }
            if let actionInfo {
                Section { Text(actionInfo).foregroundStyle(.green) }
            }
        }
        .navigationTitle("Cupo")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showAssignSheet) {
            AssignSlotSheet(slot: slot, members: members) { Task { await refresh() } }
        }
        .fullScreenCover(isPresented: $showSwapSheet) {
            RequestSwapSheet(slot: slot, members: members.filter { $0.id != currentMemberId }) { _ in
                Task { await refresh() }
            }
        }
        .task { await loadMembers() }
    }

    // MARK: - Computed

    private var assetName: String {
        asset.metadata["name"]?.stringValue ?? "Recurso"
    }

    private var assignedMemberId: UUID? {
        guard let s = slot.metadata["assigned_member_id"]?.stringValue else { return nil }
        return UUID(uuidString: s)
    }
    private var assignedMember: MemberWithProfile? {
        guard let id = assignedMemberId else { return nil }
        return members.first { $0.id == id }
    }
    private var bookingId: UUID? {
        guard let s = slot.metadata["booking_id"]?.stringValue else { return nil }
        return UUID(uuidString: s)
    }
    private var currentMemberId: UUID? {
        guard let userId = appState.session?.user.id else { return nil }
        return members.first { $0.member.userId == userId }?.id
    }

    private var canAssign: Bool {
        // Server enforces assignSlot perm. UI proxy: founder/admin role.
        guard let g = appState.activeGroup else { return false }
        // Best-effort check on cached myRole if loaded; fall back to true and let server reject.
        return slot.groupId == g.id
    }
    private var canBook: Bool {
        // Server enforces bookSlot perm. UI proxy: anyone in the group.
        // Server will reject if slot is assigned to another holder.
        slot.status == "unassigned" || slot.status == "assigned"
    }
    private var canRequestSwap: Bool {
        // Only the current holder can request a swap.
        guard let me = currentMemberId, let assigned = assignedMemberId else { return false }
        return me == assigned
    }

    // MARK: - Actions

    @MainActor
    private func book() async {
        isBooking = true
        actionError = nil
        actionInfo = nil
        defer { isBooking = false }
        do {
            let bookingId = try await appState.slotLifecycleRepo.bookSlot(slot.id)
            actionInfo = "Reservado: \(bookingId.uuidString.prefix(8))…"
            await refresh()
        } catch {
            actionError = error.localizedDescription
        }
    }

    @MainActor
    private func refresh() async {
        await loadMembers()
    }

    @MainActor
    private func loadMembers() async {
        do {
            members = try await appState.groupsRepo.membersWithProfiles(of: slot.groupId)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func rangeLabel(key: String) -> String {
        guard let raw = slot.metadata[key]?.stringValue else { return "—" }
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        let date = isoFrac.date(from: raw) ?? isoPlain.date(from: raw)
        return date?.ruulShortDate ?? raw
    }
}

// MARK: - AssignSlotSheet

struct AssignSlotSheet: View {
    let slot: ResourceRow
    let members: [MemberWithProfile]
    let onAssigned: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @State private var selected: UUID?
    @State private var isSubmitting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List(members, selection: $selected) { m in
                Text(m.displayName)
                    .tag(m.id as UUID?)
            }
            .ruulSheetToolbar("Asignar cupo")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Asignar") { Task { await submit() } }
                        .disabled(selected == nil || isSubmitting)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let error {
                    Text(error).foregroundStyle(.red).padding()
                }
            }
        }
    }

    @MainActor
    private func submit() async {
        guard let memberId = selected else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await appState.slotLifecycleRepo.assignSlot(slot.id, to: memberId)
            onAssigned()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - RequestSwapSheet

struct RequestSwapSheet: View {
    let slot: ResourceRow
    let members: [MemberWithProfile]
    let onRequested: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @State private var selected: UUID?
    @State private var isSubmitting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List(members, selection: $selected) { m in
                Text(m.displayName)
                    .tag(m.id as UUID?)
            }
            .ruulSheetToolbar("Pedir swap")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Solicitar") { Task { await submit() } }
                        .disabled(selected == nil || isSubmitting)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let error {
                    Text(error).foregroundStyle(.red).padding()
                }
            }
        }
    }

    @MainActor
    private func submit() async {
        guard let memberId = selected else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let voteId = try await appState.slotLifecycleRepo.requestSlotSwap(slot.id, to: memberId)
            onRequested(voteId)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
