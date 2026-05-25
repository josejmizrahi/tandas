import SwiftUI
import PhotosUI
import RuulUI
import RuulCore

/// Edit an existing event. Surfaces every editable field the
/// `update_event_metadata` RPC accepts so hosts can fully reshape an
/// event after creating it. Recurrence is intentionally omitted —
/// recurrence is a create-time decision.
public struct EditEventView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    @Bindable var coordinator: ResourceEditCoordinator

    @State private var coverPickerPresented = false
    @State private var photosPickerItem: PhotosPickerItem?
    @State private var members: [MemberWithProfile] = []
    @State private var hostPickerPresented = false
    @State private var rsvpDeadlineEnabled: Bool = false
    @State private var capacityEnabled: Bool = false
    @State private var capacityText: String = ""

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                    coverSection
                    titleSection
                    dateSection
                    durationSection
                    locationSection
                    hostSection
                    capacitySection
                    plusOnesSection
                    rsvpDeadlineSection
                    descriptionSection
                    rulesToggleSection
                    if let error = coordinator.error {
                        Text(error.localizedDescription)
                            .font(.caption)
                            .foregroundStyle(Color.ruulSemanticError)
                    }
                }
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.top, RuulSpacing.md)
                .padding(.bottom, 64)
            }
            .ruulSheetToolbar("Editar evento")
            .safeAreaInset(edge: .bottom) {
                saveButton
            }
            .background(Color.ruulBackground)
            .onAppear {
                rsvpDeadlineEnabled = coordinator.draft.rsvpDeadline != nil
                capacityEnabled = coordinator.draft.capacityMax != nil
                capacityText = coordinator.draft.capacityMax.map(String.init) ?? ""
            }
            .task { await loadMembers() }
            .onChange(of: coordinator.updatedEvent) { _, newValue in
                if newValue != nil { dismiss() }
            }
            .sheet(isPresented: $coverPickerPresented) {
                coverPickerSheet
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.ultraThinMaterial)
            }
            .sheet(isPresented: $hostPickerPresented) {
                hostPickerSheet
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.ultraThinMaterial)
            }
        }
    }

    // MARK: - Sections

    private var coverSection: some View {
        Button {
            coverPickerPresented = true
        } label: {
            ZStack(alignment: .bottomTrailing) {
                if let url = coordinator.draft.coverImageURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFill()
                        default: defaultCover
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))
                } else {
                    defaultCover
                        .frame(maxWidth: .infinity)
                        .frame(height: 180)
                }
                Image(systemName: "camera.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .padding(RuulSpacing.xs)
                    .background(Color.black.opacity(0.55), in: Circle())
                    .padding(RuulSpacing.sm)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cambiar portada")
    }

    private var defaultCover: some View {
        let cover = RuulCoverCatalog.cover(named: coordinator.draft.coverImageName)
        return RuulCoverView(cover)
    }

    private var titleSection: some View {
        RuulTextField(
            "Título del evento",
            text: $coordinator.draft.title,
            label: "Título"
        )
    }

    private var dateSection: some View {
        DatePicker(
            "Fecha y hora",
            selection: $coordinator.draft.startsAt,
            displayedComponents: [.date, .hourAndMinute]
        )
    }

    private var durationSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            Text("Duración")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.ruulTextPrimary)
            HStack {
                Image(systemName: "clock")
                    .foregroundStyle(Color.ruulTextSecondary)
                Stepper(value: $coordinator.draft.durationMinutes, in: 30...720, step: 30) {
                    Text(formatDuration(coordinator.draft.durationMinutes))
                        .font(.subheadline)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, RuulSpacing.sm)
            .padding(.horizontal, RuulSpacing.md)
            .ruulCardSurface(.solid)
        }
    }

    private var locationSection: some View {
        LocationAutocompletePicker(
            locationName: $coordinator.draft.locationName,
            locationLat: $coordinator.draft.locationLat,
            locationLng: $coordinator.draft.locationLng
        )
    }

    private var hostSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            Text("Anfitrión")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.ruulTextPrimary)
            Button { hostPickerPresented = true } label: {
                HStack(spacing: RuulSpacing.sm) {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(.tint)
                    Text(hostDisplayName)
                        .font(.subheadline)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.ruulTextTertiary)
                }
                .padding(.vertical, RuulSpacing.sm)
                .padding(.horizontal, RuulSpacing.md)
                .ruulCardSurface(.solid)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var capacitySection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            Toggle(isOn: $capacityEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Capacidad máxima")
                        .font(.subheadline.weight(.semibold))
                    Text(capacityEnabled
                         ? "Limita cuántos asientos puede ocupar el grupo."
                         : "Sin límite — todos pueden confirmar.")
                        .font(.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
            }
            .onChange(of: capacityEnabled) { _, newValue in
                if !newValue {
                    coordinator.draft.capacityMax = nil
                    capacityText = ""
                } else if coordinator.draft.capacityMax == nil {
                    coordinator.draft.capacityMax = 10
                    capacityText = "10"
                }
            }
            if capacityEnabled {
                HStack {
                    Image(systemName: "person.2")
                        .foregroundStyle(Color.ruulTextSecondary)
                    TextField("Asientos", text: $capacityText)
                        .keyboardType(.numberPad)
                        .onChange(of: capacityText) { _, newValue in
                            coordinator.draft.capacityMax = Int(newValue.filter(\.isNumber))
                        }
                    Text("personas")
                        .font(.subheadline)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                .padding(.vertical, RuulSpacing.sm)
                .padding(.horizontal, RuulSpacing.md)
                .ruulCardSurface(.solid)
            }
        }
    }

    private var plusOnesSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            Toggle(isOn: $coordinator.draft.allowPlusOnes) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Permitir acompañantes")
                        .font(.subheadline.weight(.semibold))
                    Text("Los asistentes pueden traer +N personas al confirmar.")
                        .font(.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
            }
            .onChange(of: coordinator.draft.allowPlusOnes) { _, newValue in
                if !newValue { coordinator.draft.maxPlusOnesPerMember = 0 }
                else if coordinator.draft.maxPlusOnesPerMember == 0 {
                    coordinator.draft.maxPlusOnesPerMember = 1
                }
            }
            if coordinator.draft.allowPlusOnes {
                HStack {
                    Image(systemName: "person.fill.badge.plus")
                        .foregroundStyle(Color.ruulTextSecondary)
                    Stepper(value: $coordinator.draft.maxPlusOnesPerMember, in: 1...10) {
                        Text("Hasta \(coordinator.draft.maxPlusOnesPerMember) por persona")
                            .font(.subheadline)
                            .monospacedDigit()
                    }
                }
                .padding(.vertical, RuulSpacing.sm)
                .padding(.horizontal, RuulSpacing.md)
                .ruulCardSurface(.solid)
            }
        }
    }

    private var rsvpDeadlineSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            Toggle(isOn: $rsvpDeadlineEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fecha límite de confirmación")
                        .font(.subheadline.weight(.semibold))
                    Text(rsvpDeadlineEnabled
                         ? "Después de esta hora ya no se aceptan RSVPs."
                         : "Sin fecha límite.")
                        .font(.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
            }
            .onChange(of: rsvpDeadlineEnabled) { _, newValue in
                if !newValue {
                    coordinator.draft.rsvpDeadline = nil
                } else if coordinator.draft.rsvpDeadline == nil {
                    coordinator.draft.rsvpDeadline = coordinator.draft.startsAt.addingTimeInterval(-3600)
                }
            }
            if rsvpDeadlineEnabled {
                DatePicker(
                    "Cierra el",
                    selection: Binding(
                        get: { coordinator.draft.rsvpDeadline ?? coordinator.draft.startsAt },
                        set: { coordinator.draft.rsvpDeadline = $0 }
                    ),
                    in: ...coordinator.draft.startsAt,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .padding(.vertical, RuulSpacing.sm)
                .padding(.horizontal, RuulSpacing.md)
                .ruulCardSurface(.solid)
            }
        }
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            Text("Descripción")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.ruulTextPrimary)
            TextField(
                "Notas, contexto, lo que quieran saber los asistentes…",
                text: $coordinator.draft.description,
                axis: .vertical
            )
            .lineLimit(3...8)
            .padding(.vertical, RuulSpacing.sm)
            .padding(.horizontal, RuulSpacing.md)
            .ruulCardSurface(.solid)
        }
    }

    private var rulesToggleSection: some View {
        Toggle(isOn: $coordinator.draft.applyRules) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Aplicar reglas del grupo")
                    .font(.subheadline)
                Text("Si está apagado, este evento no genera multas al cerrarse.")
                    .font(.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
        }
    }

    private var saveButton: some View {
        VStack(spacing: 0) {
            Divider()
            RuulButton(
                "Guardar cambios",
                style: .primary,
                size: .large,
                isLoading: coordinator.isSaving,
                fillsWidth: true
            ) {
                Task { await coordinator.save() }
            }
            .disabled(!coordinator.draft.isReadyToPublish)
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.vertical, RuulSpacing.sm)
            .ruulGlass(Rectangle(), material: .regular)
        }
    }

    // MARK: - Sheets

    @ViewBuilder
    private var coverPickerSheet: some View {
        ModalSheetTemplate(
            title: "Elegir cover",
            dismissAction: { coverPickerPresented = false }
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                Text("Galería")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.ruulTextTertiary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: RuulSpacing.sm) {
                    ForEach(RuulCoverCatalog.all) { cover in
                        Button {
                            coordinator.draft.coverImageName = cover.id
                            coordinator.draft.coverImageURL = nil
                            coverPickerPresented = false
                        } label: {
                            RuulCoverView(cover)
                                .frame(height: 80)
                                .overlay(
                                    RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
                                        .stroke(coordinator.draft.coverImageName == cover.id ? Color.ruulAccent : .clear, lineWidth: 3)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var hostPickerSheet: some View {
        NavigationStack {
            List {
                Button {
                    coordinator.draft.hostId = nil
                    hostPickerPresented = false
                } label: {
                    HStack {
                        Image(systemName: "person.slash")
                            .foregroundStyle(Color.ruulTextSecondary)
                        Text("Sin asignar")
                            .foregroundStyle(Color.ruulTextPrimary)
                        Spacer()
                        if coordinator.draft.hostId == nil {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.ruulAccent)
                        }
                    }
                }
                Section("Miembros") {
                    ForEach(members, id: \.member.userId) { mwp in
                        Button {
                            coordinator.draft.hostId = mwp.member.userId
                            hostPickerPresented = false
                        } label: {
                            HStack {
                                Image(systemName: "person.crop.circle.fill")
                                    .foregroundStyle(Color.ruulAccent)
                                Text(mwp.profile?.displayName ?? "Miembro")
                                    .foregroundStyle(Color.ruulTextPrimary)
                                Spacer()
                                if coordinator.draft.hostId == mwp.member.userId {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.ruulAccent)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Elegir anfitrión")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cerrar") { hostPickerPresented = false }
                }
            }
        }
    }

    // MARK: - Helpers

    private var hostDisplayName: String {
        guard let hostId = coordinator.draft.hostId else { return "Sin asignar" }
        return members.first(where: { $0.member.userId == hostId })?.profile?.displayName ?? "Miembro"
    }

    @MainActor
    private func loadMembers() async {
        let rows = (try? await app.groupsRepo.membersWithProfiles(of: coordinator.group.id)) ?? []
        members = rows.sorted(by: { ($0.profile?.displayName ?? "") < ($1.profile?.displayName ?? "") })
    }

    private func formatDuration(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 { return "\(m) min" }
        if m == 0 { return "\(h) h" }
        return "\(h) h \(m) min"
    }
}
