import SwiftUI
import RuulUI
import RuulCore

/// Space-specific inline sections rendered by `UniversalResourceDetailView`
/// when `resource.resourceType == .space`. Mirror del pattern asset sections
/// (Sections/Asset/AssetSections.swift) — cada faceta es un componente
/// independiente bajo `Features/Resources/Detail/Sections/Space/`, gated by
/// capability flags en el parent view.
///
/// Capabilities → sección:
///   capacity        → SpaceCapacitySection      (declared cap vs current load + waitlist)
///   check_in        → SpaceOccupancySection     (members currently inside)
///   booking         → SpaceBookingsSection      (active bookings + cancel + book CTA)
///
/// Todas las secciones leen las projections del mig 00267 vía
/// `app.spaceProjectionRepo`. Mutaciones flow through
/// `app.spaceLifecycleRepo` (mig 00266 RPCs). Refresh es kick-based off
/// de un `refreshToken: Int` interno por sección.

// MARK: - Capacity

@MainActor
public struct SpaceCapacitySection: View {
    @Environment(AppState.self) private var app
    public let space: ResourceRow

    @State private var snapshot: SpaceCapacityRow?
    @State private var error: String?

    public init(space: ResourceRow) {
        self.space = space
    }

    /// Catalog registration — space-only via isVisibleFor, gated on the
    /// `capacity` capability. Per Plans/Active/Space.md §16 + §22.
    public static let definition = CapabilitySection(
        id: "space.capacity",
        priority: 164,
        isEnabledFor: { caps in caps.contains("capacity") },
        isVisibleFor: { ctx in ctx.resource.resourceType == .space },
        render: { ctx in AnyView(SpaceCapacitySection(space: ctx.resource)) }
    )

    public var body: some View {
        RuulInfoCard("AFORO") {
            if let snapshot {
                RuulInfoRow(
                    label: "Capacidad",
                    value: snapshot.capacity.map { "\($0)" } ?? "Ilimitada"
                )
                RuulInfoDivider()
                RuulInfoRow(label: "Reservas activas", value: "\(snapshot.activeBookings)")
                if let remaining = snapshot.remaining {
                    RuulInfoDivider()
                    RuulInfoRow(label: "Libres", value: "\(remaining)")
                }
                if snapshot.waitlistCount > 0 {
                    RuulInfoDivider()
                    RuulInfoRow(label: "En lista de espera", value: "\(snapshot.waitlistCount)")
                }
                if snapshot.isFull {
                    RuulInfoDivider()
                    Text("Espacio lleno — únete a la lista de espera")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .padding(RuulSpacing.md)
                }
            } else {
                RuulInfoRow(label: "Capacidad", value: "—")
            }
            if let error {
                RuulInfoDivider()
                Text(error)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulNegative)
                    .padding(RuulSpacing.md)
            }
        }
        .task(id: space.id) { await load() }
    }

    @MainActor
    private func load() async {
        do {
            snapshot = try await app.spaceProjectionRepo.capacity(for: space.id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Occupancy

@MainActor
public struct SpaceOccupancySection: View {
    @Environment(AppState.self) private var app
    public let space: ResourceRow
    public let onMetadataChanged: () async -> Void

    @State private var rows: [SpaceOccupancyRow] = []
    @State private var members: [MemberWithProfile] = []
    @State private var isCheckingIn = false
    @State private var error: String?

    public init(
        space: ResourceRow,
        onMetadataChanged: @escaping () async -> Void = {}
    ) {
        self.space = space
        self.onMetadataChanged = onMetadataChanged
    }

    /// Catalog registration — space-only via isVisibleFor, gated on the
    /// `check_in` capability. Per Plans/Active/Space.md §16. The canonical
    /// `CheckInSectionView` (id "check_in") still runs for events via the
    /// inline path because it depends on @Environment(eventInteractor)
    /// not available in the catalog render closure today.
    public static let definition = CapabilitySection(
        id: "space.occupancy",
        priority: 165,
        isEnabledFor: { caps in caps.contains("check_in") },
        isVisibleFor: { ctx in ctx.resource.resourceType == .space },
        render: { ctx in AnyView(SpaceOccupancySection(
            space: ctx.resource,
            onMetadataChanged: { await ctx.onResourceMutated() }
        )) }
    )

    public var body: some View {
        RuulInfoCard("AHORA") {
            if rows.isEmpty {
                RuulInfoRow(label: "Nadie en el espacio", value: "")
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.memberId) { idx, row in
                    if idx > 0 { RuulInfoDivider() }
                    RuulInfoRow(
                        label: displayName(for: row.memberId),
                        value: SpaceDateFormatter.timeOfDay(row.checkedInAt)
                    )
                }
            }
            RuulInfoDivider()
            RuulInfoActionRow(
                label: isCheckingIn ? "Registrando..." : "Marcar mi llegada",
                symbol: "checkmark.circle"
            ) {
                Task { await checkIn() }
            }
            if let error {
                RuulInfoDivider()
                Text(error)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulNegative)
                    .padding(RuulSpacing.md)
            }
        }
        .task(id: space.id) { await load() }
    }

    private func displayName(for memberId: UUID) -> String {
        members.first { $0.id == memberId }?.displayName ?? "Miembro"
    }

    @MainActor
    private func load() async {
        async let rowsTask = app.spaceProjectionRepo.occupancy(for: space.id)
        async let membersTask = app.groupsRepo.membersWithProfiles(of: space.groupId)
        do {
            rows = try await rowsTask
            members = (try? await membersTask) ?? []
            error = nil
        } catch {
            self.error = error.localizedDescription
            members = (try? await membersTask) ?? []
        }
    }

    @MainActor
    private func checkIn() async {
        isCheckingIn = true
        defer { isCheckingIn = false }
        do {
            _ = try await app.spaceLifecycleRepo.checkInToSpace(
                space: space.id, booking: nil, notes: nil
            )
            error = nil
            await load()
            await onMetadataChanged()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Bookings

@MainActor
public struct SpaceBookingsSection: View {
    @Environment(AppState.self) private var app
    public let space: ResourceRow
    public let onMetadataChanged: () async -> Void

    @State private var rows: [SpaceAvailabilityRow] = []
    @State private var members: [MemberWithProfile] = []
    @State private var showBook: Bool = false
    @State private var error: String?
    @State private var capacityState: SpaceCapacityRow?

    public init(
        space: ResourceRow,
        onMetadataChanged: @escaping () async -> Void = {}
    ) {
        self.space = space
        self.onMetadataChanged = onMetadataChanged
    }

    /// Catalog registration — space-only via isVisibleFor, gated on the
    /// `booking` capability. Per Plans/Active/Space.md §16. The asset
    /// counterpart (id "asset.bookings") gates the same `booking` cap
    /// with `resourceType == .asset`; the universal stub `booking`
    /// section is filtered out by the view for both asset and space.
    public static let definition = CapabilitySection(
        id: "space.bookings",
        priority: 166,
        isEnabledFor: { caps in caps.contains("booking") },
        isVisibleFor: { ctx in ctx.resource.resourceType == .space },
        render: { ctx in AnyView(SpaceBookingsSection(
            space: ctx.resource,
            onMetadataChanged: { await ctx.onResourceMutated() }
        )) }
    )

    public var body: some View {
        RuulInfoCard("RESERVAS") {
            if rows.isEmpty {
                RuulInfoRow(label: "Sin reservas activas", value: "")
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.bookingId) { idx, row in
                    if idx > 0 { RuulInfoDivider() }
                    RuulInfoRow(
                        label: displayName(for: row.memberId),
                        value: windowLabel(row)
                    )
                    if canCancel(row) {
                        RuulInfoDivider()
                        RuulInfoActionRow(
                            label: "Cancelar reserva",
                            symbol: "xmark.circle",
                            isDestructive: true
                        ) {
                            Task { await cancel(row.bookingId) }
                        }
                    }
                }
            }
            RuulInfoDivider()
            if isFull {
                RuulInfoActionRow(
                    label: "Unirme a la lista de espera",
                    symbol: "person.crop.circle.badge.clock"
                ) {
                    Task { await joinWaitlist() }
                }
            } else {
                RuulInfoActionRow(
                    label: "Reservar",
                    symbol: "calendar.badge.plus"
                ) { showBook = true }
            }
            if let error {
                RuulInfoDivider()
                Text(error)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulNegative)
                    .padding(RuulSpacing.md)
            }
        }
        .task(id: space.id) { await load() }
        .sheet(isPresented: $showBook) {
            BookSpaceSheet(space: space) {
                Task {
                    await load()
                    await onMetadataChanged()
                }
            }
            .environment(app)
        }
    }

    private var isFull: Bool {
        capacityState?.isFull ?? false
    }

    private func displayName(for memberId: UUID) -> String {
        members.first { $0.id == memberId }?.displayName ?? "Miembro"
    }

    private func windowLabel(_ row: SpaceAvailabilityRow) -> String {
        switch (row.startsAt, row.endsAt) {
        case let (start?, end?):
            return "\(SpaceDateFormatter.shortDateTime(start)) → \(SpaceDateFormatter.timeOfDay(end))"
        case let (start?, nil):
            return "Desde \(SpaceDateFormatter.shortDateTime(start))"
        case let (nil, end?):
            return "Hasta \(SpaceDateFormatter.shortDateTime(end))"
        case (nil, nil):
            return "Abierta"
        }
    }

    private func canCancel(_ row: SpaceAvailabilityRow) -> Bool {
        // Caller can cancel own booking; admin guard handled server-side.
        // We optimistically expose the affordance and let the RPC reject
        // with a friendly error if the caller doesn't have rights.
        true
    }

    @MainActor
    private func load() async {
        async let rowsTask = app.spaceProjectionRepo.availability(for: space.id)
        async let membersTask = app.groupsRepo.membersWithProfiles(of: space.groupId)
        async let capacityTask = app.spaceProjectionRepo.capacity(for: space.id)
        do {
            rows = try await rowsTask
            members = (try? await membersTask) ?? []
            capacityState = try? await capacityTask
            error = nil
        } catch {
            self.error = error.localizedDescription
            members = (try? await membersTask) ?? []
            capacityState = try? await capacityTask
        }
    }

    @MainActor
    private func cancel(_ bookingId: UUID) async {
        do {
            try await app.spaceLifecycleRepo.cancelBooking(booking: bookingId, reason: nil)
            error = nil
            await load()
            await onMetadataChanged()
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func joinWaitlist() async {
        do {
            _ = try await app.spaceLifecycleRepo.joinWaitlist(
                space: space.id, priority: 0, notes: nil
            )
            error = nil
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Book sheet

struct BookSpaceSheet: View {
    let space: ResourceRow
    let onBooked: () -> Void

    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var hasWindow: Bool = true
    @State private var startsAt: Date = .now.addingTimeInterval(3600)
    @State private var endsAt: Date = .now.addingTimeInterval(2 * 3600)
    @State private var notes: String = ""
    @State private var isSubmitting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Ventana") {
                    Toggle("Fijar horario", isOn: $hasWindow)
                    if hasWindow {
                        DatePicker("Desde", selection: $startsAt)
                        DatePicker("Hasta", selection: $endsAt)
                    }
                }
                Section("Notas (opcional)") {
                    TextField("Detalles para el grupo", text: $notes, axis: .vertical)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .ruulSheetToolbar("Reservar \(spaceName)")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Reservar") { Task { await submit() } }
                        .disabled(isSubmitting || (hasWindow && endsAt <= startsAt))
                }
            }
        }
    }

    private var spaceName: String {
        space.metadata["name"]?.stringValue ?? "espacio"
    }

    @MainActor
    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            _ = try await app.spaceLifecycleRepo.bookSpace(
                space: space.id,
                startsAt: hasWindow ? startsAt : nil,
                endsAt: hasWindow ? endsAt : nil,
                notes: notes.isEmpty ? nil : notes
            )
            onBooked()
            dismiss()
        } catch let e as SpaceLifecycleError {
            self.error = e.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Formatters

enum SpaceDateFormatter {
    static func timeOfDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }

    static func shortDateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.timeStyle = .short
        f.dateStyle = .short
        return f.string(from: date)
    }
}

// MARK: - INFORMACIÓN rows

/// Space-specific INFORMACIÓN rows. Extracted from
/// `UniversalResourceDetailView.typeSpecificRows` per ontology
/// constitution Rule 6. Registered with `ResourceInfoRegistry` at boot.
@MainActor
public enum SpaceInfoProvider {
    public static func rows(for ctx: ResourceDetailContext) -> [ResourceInfoRow] {
        var out: [ResourceInfoRow] = []
        // `create_space` (mig 00207) writes `metadata.location_name`.
        // Earlier code read the wrong key (`address`); fallback to
        // `locationName` for any future codepath using camelCase.
        let address = ctx.resource.metadata["location_name"]?.stringValue
            ?? ctx.resource.metadata["locationName"]?.stringValue
        if let address, !address.isEmpty {
            out.append(ResourceInfoRow(label: "Dirección", value: address))
        }
        if let cap = ctx.resource.metadata["capacity"]?.intValue {
            out.append(ResourceInfoRow(label: "Capacidad", value: "\(cap)"))
        }
        return out
    }
}
