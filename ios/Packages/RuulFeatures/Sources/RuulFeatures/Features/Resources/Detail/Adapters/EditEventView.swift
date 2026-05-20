import SwiftUI
import PhotosUI
import RuulUI
import RuulCore

/// Edit an existing event. Mirrors CreateEventView's structure (cover, title,
/// date, location, host, description, rules toggle) but seeds from the current
/// event and submits via `updateEvent` instead of `createEvent`.
/// Recurrence card is intentionally omitted — recurrence is decided at create
/// time, not edit time.
public struct EditEventView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var coordinator: ResourceEditCoordinator

    @State private var coverPickerPresented = false
    @State private var photosPickerItem: PhotosPickerItem?

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                    coverSection
                    titleSection
                    dateSection
                    locationSection
                    hostSection
                    descriptionSection
                    rulesToggleSection
                    if let error = coordinator.error {
                        Text(error.localizedDescription)
                            .font(.caption)
                            .foregroundStyle(Color.red)
                    }
                }
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.top, RuulSpacing.md)
                .padding(.bottom, RuulSpacing.s10)
            }
            .ruulSheetToolbar("Editar evento")
            .safeAreaInset(edge: .bottom) {
                saveButton
            }
            .background(Color.ruulBackground)
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
                    .clipShape(RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
                } else {
                    defaultCover
                        .frame(maxWidth: .infinity)
                        .frame(height: 180)
                }
                Image(systemName: "camera.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .padding(RuulSpacing.xs)
                    .background(Color.ruulImageBadge, in: Circle())
                    .padding(RuulSpacing.sm)
            }
        }
        .buttonStyle(.ruulPress)
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
        // Post BigBang: presence of `rotating_host` module proxies "this
        // group has hosts". Phase 2 rotation capability will refine this.
        if coordinator.group.effectiveActiveModules.contains(GroupModule.rotatingHost.id) {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text("HOST")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                RuulCard(.tile) {
                    HStack(spacing: RuulSpacing.sm) {
                        RuulIconBadge("person.fill", size: .small)
                        Text(coordinator.draft.hostId == nil ? "Sin asignar" : "Asignado")
                            .font(.subheadline)
                            .foregroundStyle(Color.primary)
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
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.vertical, RuulSpacing.sm)
            // DS v3 §13: sticky CTA chrome — Liquid Glass real.
            .ruulGlass(Rectangle(), material: .regular)
        }
    }

    @ViewBuilder
    private var coverPickerSheet: some View {
        ModalSheetTemplate(
            title: "Elegir cover",
            dismissAction: { coverPickerPresented = false }
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                Text("GALERÍA")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
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
                                    RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
                                        .stroke(coordinator.draft.coverImageName == cover.id ? Color.ruulAccent : .clear, lineWidth: 3)
                                )
                        }
                        .buttonStyle(.ruulPress)
                    }
                }
            }
        }
    }
}
