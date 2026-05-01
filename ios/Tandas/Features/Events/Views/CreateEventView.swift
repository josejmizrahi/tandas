import SwiftUI
import PhotosUI

struct CreateEventView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var coordinator: EventCreationCoordinator

    @State private var coverPickerPresented = false
    @State private var photosPickerItem: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.s5) {
                    coverSection
                    titleSection
                    dateSection
                    if coordinator.recurrenceAvailable {
                        RecurrenceOptionsCard(
                            selection: $coordinator.draft.recurrenceOption,
                            group: coordinator.group
                        )
                    }
                    locationSection
                    hostSection
                    descriptionSection
                    rulesToggleSection
                }
                .padding(.horizontal, RuulSpacing.s5)
                .padding(.top, RuulSpacing.s4)
                .padding(.bottom, RuulSpacing.s10)  // room for sticky CTA
            }
            .navigationTitle("Nuevo evento")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") {
                        Task {
                            await coordinator.recordAbandon()
                            dismiss()
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                publishButton
            }
            .background(Color.ruulBackgroundCanvas)
            .onChange(of: coordinator.createdEvent) { _, newValue in
                if newValue != nil { dismiss() }
            }
            .ruulSheet(isPresented: $coverPickerPresented) {
                coverPickerSheet
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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(8)
                    .background(Color.black.opacity(0.55), in: Circle())
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
        VStack(alignment: .leading, spacing: RuulSpacing.s3) {
            RuulTextField(
                placeholder,
                text: $coordinator.draft.title,
                label: "Título"
            )
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: RuulSpacing.s2) {
                    ForEach(suggestions, id: \.self) { sug in
                        RuulChip(sug, style: .suggestion) {
                            coordinator.draft.title = sug
                        }
                    }
                }
            }
        }
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
                Text("Host")
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulTextSecondary)
                RuulCard(.glass) {
                    HStack(spacing: RuulSpacing.s3) {
                        RuulIconBadge("person.fill", size: .small)
                        Text(hostLabel)
                            .ruulTextStyle(RuulTypography.body)
                            .foregroundStyle(Color.ruulTextPrimary)
                        Spacer()
                        if coordinator.group.rotationMode == .autoOrder {
                            Text("Sugerido")
                                .ruulTextStyle(RuulTypography.caption)
                                .foregroundStyle(Color.ruulTextTertiary)
                        }
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

    private var publishButton: some View {
        VStack(spacing: 0) {
            Divider()
            RuulButton(
                "Crear y publicar",
                style: .primary,
                size: .large,
                isLoading: coordinator.isPublishing,
                fillsWidth: true
            ) {
                Task { await coordinator.publish() }
            }
            .disabled(!coordinator.draft.isReadyToPublish)
            .padding(.horizontal, RuulSpacing.s5)
            .padding(.vertical, RuulSpacing.s3)
            .background(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    private var coverPickerSheet: some View {
        ModalSheetTemplate(
            title: "Elegir cover",
            dismissAction: { coverPickerPresented = false }
        ) {
            VStack(alignment: .leading, spacing: RuulSpacing.s5) {
                Text("Galería")
                    .ruulTextStyle(RuulTypography.footnote)
                    .foregroundStyle(Color.ruulTextSecondary)
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
                Divider()
                PhotosPicker(selection: $photosPickerItem, matching: .images) {
                    photosPickerLabel
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var photosPickerLabel: some View {
        HStack(spacing: RuulSpacing.s3) {
            Image(systemName: "photo.on.rectangle")
                .foregroundStyle(Color.ruulAccentPrimary)
            Text("Subir foto propia")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextPrimary)
            Spacer()
        }
        .padding(RuulSpacing.s4)
        .ruulGlass(RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous), material: .regular, interactive: true)
    }

    // MARK: - Computed

    private var placeholder: String {
        let vocab = coordinator.group.eventVocabulary
        return "\(vocab.capitalized) de los \(coordinator.draft.startsAt.ruulWeekday.lowercased())"
    }

    private var suggestions: [String] {
        let vocab = coordinator.group.eventVocabulary.capitalized
        let weekday = coordinator.draft.startsAt.ruulWeekday
        let monthFormatter = DateFormatter()
        monthFormatter.locale = Locale(identifier: "es_MX")
        monthFormatter.dateFormat = "MMMM"
        let month = monthFormatter.string(from: coordinator.draft.startsAt).capitalized
        return [
            "\(vocab) del \(weekday.lowercased())",
            "\(vocab) de \(month)",
            "\(vocab) especial"
        ]
    }

    private var hostLabel: String {
        switch coordinator.group.rotationMode {
        case .autoOrder: return "Próximo en orden"
        case .manual:    return "Sin asignar — escoge después"
        case .noHost:    return ""
        }
    }
}
