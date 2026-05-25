import SwiftUI
import RuulUI
import RuulCore

/// Detail de un turno (sub-unidad de un activo). Doctrine v2 (2026-05-25):
/// renderiza vía `ResourceDetailContent` igual que Event/Fund/Space/Fine —
/// "same world". Vocabulario humanizado: "Cupo" → "Turno", status state
/// machine → frase ("Le toca a José" / "Disponible").
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
        ResourceDetailContent(config: makeConfig())
            .fullScreenCover(isPresented: $showAssignSheet) {
                AssignSlotSheet(slot: slot, members: members) { Task { await refresh() } }
            }
            .fullScreenCover(isPresented: $showSwapSheet) {
                RequestSwapSheet(
                    slot: slot,
                    members: members.filter { $0.id != currentMemberId }
                ) { _ in Task { await refresh() } }
            }
            .task { await loadMembers() }
            .navigationTitle("Turno")
            .navigationBarTitleDisplayMode(.inline)
            .alert(
                "No pudimos hacer el cambio",
                isPresented: Binding(
                    get: { actionError != nil },
                    set: { if !$0 { actionError = nil } }
                ),
                presenting: actionError
            ) { _ in
                Button("OK", role: .cancel) { actionError = nil }
            } message: { msg in
                Text(msg)
            }
    }

    // MARK: - Config

    private func makeConfig() -> ResourceConfig {
        ResourceConfig.slot(
            SlotInput(
                id: slot.id.uuidString,
                assetName: assetName,
                timeRangeLabel: timeRangeLabel,
                statusLabel: humanStatus,
                titularPerson: titularPersonForDetail,
                canAssign: canAssign,
                canBook: canBook,
                canRequestSwap: canRequestSwap
            ),
            onBook: { Task { await book() } },
            onAssign: { showAssignSheet = true },
            onRequestSwap: { showSwapSheet = true }
        )
    }

    // MARK: - Derived

    private var assetName: String {
        asset.metadata["name"]?.stringValue ?? "Recurso"
    }

    private var assignedMemberId: UUID? {
        guard let raw = slot.metadata["assigned_member_id"]?.stringValue else { return nil }
        return UUID(uuidString: raw)
    }

    private var assignedMember: MemberWithProfile? {
        guard let id = assignedMemberId else { return nil }
        return members.first { $0.id == id }
    }

    private var bookingId: UUID? {
        guard let raw = slot.metadata["booking_id"]?.stringValue else { return nil }
        return UUID(uuidString: raw)
    }

    private var currentMemberId: UUID? {
        guard let userId = appState.session?.user.id else { return nil }
        return members.first { $0.member.userId == userId }?.id
    }

    /// Maps the wire status string + assignment metadata into a single
    /// human phrase ("Le toca a José" / "Disponible" / "Reservado").
    /// Per doctrine v2 §7: the state machine label never appears verbatim.
    private var humanStatus: String {
        if let assigned = assignedMember {
            return "Le toca a \(assigned.displayName)"
        }
        switch slot.status {
        case "unassigned": return "Disponible"
        case "assigned":   return "Asignado"
        case "booked":     return "Reservado"
        default:           return slot.status.capitalized
        }
    }

    /// Renders the titular as a `Person` for the avatars section.
    /// Nil when unassigned — the factory falls back to the empty-state row.
    private var titularPersonForDetail: Person? {
        guard let mw = assignedMember else { return nil }
        return Person(
            id: mw.id.uuidString,
            name: mw.displayName,
            initials: initials(mw.displayName),
            color: ResourceFamilyTint.persons.color,
            imageURL: mw.avatarURL
        )
    }

    private var timeRangeLabel: String {
        let start = parseISO(slot.metadata["starts_at"]?.stringValue)?.ruulShortDate
        let end = parseISO(slot.metadata["ends_at"]?.stringValue)?.ruulShortTime
        switch (start, end) {
        case let (s?, e?): return "\(s) · hasta \(e)"
        case let (s?, nil): return s
        case let (nil, e?): return "Hasta \(e)"
        default: return "Sin fecha"
        }
    }

    private var canAssign: Bool {
        guard let g = appState.activeGroup else { return false }
        return slot.groupId == g.id
    }

    private var canBook: Bool {
        slot.status == "unassigned" || slot.status == "assigned"
    }

    private var canRequestSwap: Bool {
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
            _ = try await appState.slotLifecycleRepo.bookSlot(slot.id)
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

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ")
        let first = parts.first.map(String.init).flatMap { $0.first.map(String.init) } ?? ""
        let last = parts.dropFirst().last.map(String.init).flatMap { $0.first.map(String.init) } ?? ""
        return (first + last).uppercased()
    }

    private func parseISO(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFrac.date(from: raw) { return d }
        return ISO8601DateFormatter().date(from: raw)
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
            .ruulSheetToolbar("Asignar turno")
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
            .ruulSheetToolbar("Pedir intercambio")
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
