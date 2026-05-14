import SwiftUI
import PhotosUI
import RuulUI
import RuulCore

public struct CreateEventView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var coordinator: ResourceCreationCoordinator

    @State private var coverPickerPresented = false
    @State private var photosPickerItem: PhotosPickerItem?
    /// W3-B3: collapsed by default. Audit Track B flagged the 7-section
    /// CreateEventView as overwhelming for first-time users; description
    /// + apply-rules toggle now sit behind a tap so the primary path is
    /// just name + date + (host if rotation).
    @State private var moreOptionsExpanded = false

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.lg) {
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
                    moreOptionsDisclosure
                }
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.top, RuulSpacing.md)
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
            .background(Color.ruulBackground)
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
                    .clipShape(RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous))
                } else {
                    defaultCover
                        .frame(maxWidth: .infinity)
                        .frame(height: 180)
                }
                Image(systemName: "camera.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ruulOnImage)
                    .padding(RuulSpacing.xs)
                    .background(Color.ruulImageBadge, in: Circle())
                    .padding(RuulSpacing.sm)
                    .accessibilityHidden(true)
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
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            RuulTextField(
                placeholder,
                text: $coordinator.draft.title,
                label: "Título"
            )
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: RuulSpacing.xs) {
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
        // Host rotation moves to the rotation capability on a Resource (Phase 2).
        // Until that lands, host always shows as "no host yet" — the founder
        // can assign manually post-creation via the rotation module's UI.
        if rotationActive {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                // W2-C4: "Host" → "Anfitrión" canon.
                Text("Anfitrión")
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(Color.ruulTextSecondary)
                RuulCard(.glass) {
                    HStack(spacing: RuulSpacing.sm) {
                        RuulIconBadge("person.fill", size: .small)
                        Text(hostLabel)
                            .ruulTextStyle(RuulTypography.body)
                            .foregroundStyle(Color.ruulTextPrimary)
                        Spacer()
                        if rotationAuto {
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

    /// W3-B3: progressive disclosure. Less-important fields (description
    /// + apply-rules) live behind "Más opciones" so first-time users
    /// see a clean name+date+host primary path. Existing power users
    /// expand once and the state survives the screen session.
    @ViewBuilder
    private var moreOptionsDisclosure: some View {
        DisclosureGroup(isExpanded: $moreOptionsExpanded) {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                descriptionSection
                rulesToggleSection
            }
            .padding(.top, RuulSpacing.md)
        } label: {
            Text("Más opciones")
                .ruulTextStyle(RuulTypography.headline)
                .foregroundStyle(Color.ruulTextPrimary)
        }
        .tint(Color.ruulTextSecondary)
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
                Text("Galería")
                    .ruulTextStyle(RuulTypography.footnote)
                    .foregroundStyle(Color.ruulTextSecondary)
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
                Divider()
                PhotosPicker(selection: $photosPickerItem, matching: .images) {
                    photosPickerLabel
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var photosPickerLabel: some View {
        HStack(spacing: RuulSpacing.sm) {
            Image(systemName: "photo.on.rectangle")
                .foregroundStyle(Color.ruulAccent)
                .accessibilityHidden(true)
            Text("Subir foto propia")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextPrimary)
            Spacer()
        }
        .padding(RuulSpacing.md)
        // No `interactive: true` — iOS 26.x swallows taps; PhotosPicker
        // already provides its own press feedback via `.buttonStyle(.plain)`
        // wrapper at the call site.
        .ruulGlass(RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous), material: .regular)
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
        // Phase 2 ResourceSeries / rotation capability will compute this.
        rotationAuto ? "Próximo en orden" : "Sin asignar — escoge después"
    }

    /// Phase-2 rotation gate. True when the `rotating_host` module is active
    /// for this group. Until ResourceSeries / rotation capability ships,
    /// presence of the module on the group is the proxy.
    private var rotationActive: Bool {
        coordinator.group.effectiveActiveModules.contains(GroupModule.rotatingHost.id)
    }

    private var rotationAuto: Bool {
        rotationActive
    }
}
