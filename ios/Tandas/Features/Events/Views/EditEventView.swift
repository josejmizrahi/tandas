import SwiftUI
import PhotosUI

/// Edit an existing event. Mirrors CreateEventView's structure (cover, title,
/// date, location, host, description, rules toggle) but seeds from the current
/// event and submits via `updateEvent` instead of `createEvent`.
/// Recurrence card is intentionally omitted — recurrence is decided at create
/// time, not edit time.
struct EditEventView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var coordinator: EventEditCoordinator

    @State private var coverPickerPresented = false
    @State private var photosPickerItem: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.s5) {
                    coverSection
                    titleSection
                    dateSection
                    locationSection
                    hostSection
                    descriptionSection
                    rulesToggleSection
                    if let error = coordinator.error {
                        Text(error.localizedDescription)
                            .ruulTextStyle(RuulTypography.caption)
                            .foregroundStyle(Color.ruulSemanticError)
                    }
                }
                .padding(.horizontal, RuulSpacing.s5)
                .padding(.top, RuulSpacing.s4)
                .padding(.bottom, RuulSpacing.s10)
            }
            .navigationTitle("Editar evento")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                saveButton
            }
            .background(Color.ruulBackgroundCanvas)
            .onChange(of: coordinator.updatedEvent) { _, newValue in
                if newValue != nil { dismiss() }
            }
            .ruulSheet(isPresented: $coverPickerPresented) {
                coverPickerSheet
            }
        }
    }

    // MARK: - Sections (mirror CreateEventView pattern)

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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ruulOnImage)
                    .padding(8)
                    .background(Color.ruulImageScrim(.badge), in: Circle())
                    .padding(RuulSpacing.s3)
            }
        }
        .buttonStyle(.ruulPress)
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
        RuulDatePicker(
            "Fecha y hora",
            date: $coordinator.draft.startsAt,
            components: [.date, .hourAndMinute]
        )
    }

    private var locationSection: some View {
        LocationAutocompletePicker(
            locationName: $coordinator.draft.locationName,
            locationLat: $coordinator.draft.locationLat,
            locationLng: $coordinator.draft.locationLng
        )
    }

    @ViewBuilder
    private var hostSection: some View {
        if coordinator.group.rotationMode != .noHost {
            VStack(alignment: .leading, spacing: RuulSpacing.s2) {
                Text("HOST")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                RuulCard(.tile) {
                    HStack(spacing: RuulSpacing.s3) {
                        RuulIconBadge("person.fill", size: .small)
                        Text(coordinator.draft.hostId == nil ? "Sin asignar" : "Asignado")
                            .ruulTextStyle(RuulTypography.body)
                            .foregroundStyle(Color.ruulTextPrimary)
                        Spacer()
                    }
                }
            }
        }
    }

    private var descriptionSection: some View {
        RuulTextField(
            "Notas (opcional)",
            text: $coordinator.draft.description,
            label: "Descripción"
        )
    }

    private var rulesToggleSection: some View {
        RuulToggle(
            "Aplicar reglas del grupo",
            isOn: $coordinator.draft.applyRules,
            description: "Si está apagado, este evento no genera multas al cerrarse."
        )
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
            .padding(.horizontal, RuulSpacing.s5)
            .padding(.vertical, RuulSpacing.s3)
            .background(.regularMaterial)
        }
    }

    @ViewBuilder
    private var coverPickerSheet: some View {
        ModalSheetTemplate(
            title: "Elegir cover",
            dismissAction: { coverPickerPresented = false }
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.s5) {
                Text("GALERÍA")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: RuulSpacing.s3) {
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
                                        .stroke(coordinator.draft.coverImageName == cover.id ? Color.ruulAccentPrimary : .clear, lineWidth: 3)
                                )
                        }
                        .buttonStyle(.ruulPress)
                    }
                }
            }
        }
    }
}
