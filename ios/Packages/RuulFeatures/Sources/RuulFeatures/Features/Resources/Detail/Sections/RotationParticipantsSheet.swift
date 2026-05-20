import SwiftUI
import RuulCore
import RuulUI

/// Configures who rotates as anfitrión for a recurring event series and
/// in what order. Persists to `resource_series.metadata.capability_configs.
/// rotation`, which the server-side cron (`auto-generate-events` +
/// `next_host_for_series`, mig 00132) reads on each upcoming occurrence
/// to pick the next host.
///
/// Surface:
///   - Member multi-picker (reuses `MemberMultiPickerField` — selection
///     order becomes the rotation order).
///   - "Orden" segmented picker: secuencial vs aleatorio.
///   - "Si el elegido no puede" segmented picker: pasa al siguiente vs
///     se queda hasta el swap.
///
/// Submit path:
///   `ResourceSeriesRepository.setRotationConfig(seriesId, participants,
///   order, replacementPolicy, purpose='host')` → direct UPDATE on
///   `resource_series.metadata`. The cron picks up the change on the
///   next batch.
///
/// Founder voice: no "capability", no "atom", no "rotation engine". The
/// header says "Anfitriones que rotan", the footer reads "El siguiente
/// turno se asigna solo cuando llegue el día."
public struct RotationParticipantsSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let eventId: UUID
    /// Called after a successful save so the parent (post-create intent
    /// screen, resource detail) can refresh the rotation section.
    public let onSaved: () -> Void

    @State private var phase: LoadPhase<Loaded> = .idle
    @State private var selectedUserIds: [String] = []
    @State private var order: String = "sequential"
    @State private var replacementPolicy: String = "skip_to_next"
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?

    /// Bundle of data the sheet needs once the event + series have been
    /// resolved. Held inside the `LoadPhase` so the editor renders only
    /// when both are loaded — keeps the view body branch-free.
    private struct Loaded: Sendable {
        let seriesId: UUID
        /// Current event's cycle_number. Passed as cycle_offset on
        /// save so the next occurrence (cycle+1) lands at
        /// participants[0] — the user's mental model of "el primero
        /// de mi lista es el próximo anfitrión". Mig 00336.
        let currentCycle: Int
    }

    public init(eventId: UUID, onSaved: @escaping () -> Void) {
        self.eventId = eventId
        self.onSaved = onSaved
    }

    public var body: some View {
        NavigationStack {
            content
                .ruulSheetToolbar("Anfitriones que rotan")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isSubmitting ? "Guardando…" : "Guardar") {
                            Task { await submit() }
                        }
                        .disabled(!canSubmit)
                    }
                }
        }
        .task { await load() }
    }

    // MARK: - Phase rendering

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle, .loading:
            loadingState
        case .failed(let err, _):
            errorState(message: err.title)
        case .empty:
            // A recurring event without a series shouldn't happen post-
            // Sprint 2 wiring, but be honest about it instead of silently
            // showing an empty picker.
            errorState(message: "Este evento no es parte de una serie. No se puede configurar rotación.")
        case .loaded, .refreshing:
            editor
        }
    }

    private var loadingState: some View {
        VStack(spacing: RuulSpacing.md) {
            ProgressView()
                .controlSize(.large)
            Text("Cargando miembros…")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: RuulSpacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(Color.red)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.primary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, RuulSpacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Editor

    private var editor: some View {
        Form {
            Section {
                MemberMultiPickerField(
                    label: "Miembros que rotan",
                    helpText: "Selecciona en el orden en que les toca.",
                    binding: $selectedUserIds
                )
            } footer: {
                Text("El primer turno será para quien aparezca primero. El siguiente se asigna solo cuando llegue el día.")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }

            Section {
                Picker("Orden", selection: $order) {
                    Text("En orden de la lista").tag("sequential")
                    Text("Aleatorio").tag("random")
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Orden")
            } footer: {
                Text(order == "random"
                     ? "Cada evento elige aleatoriamente del grupo seleccionado."
                     : "Sigue el orden en que los seleccionaste arriba. Cuando llega al final, vuelve a empezar.")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }

            Section {
                Picker("Si el elegido no puede", selection: $replacementPolicy) {
                    Text("Le toca al siguiente").tag("skip_to_next")
                    Text("Se queda hasta que cambie").tag("host_stays_until_swap")
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Si el elegido no puede")
            } footer: {
                Text(replacementPolicy == "host_stays_until_swap"
                     ? "El elegido sigue siendo el anfitrión hasta que alguien acepte cambiar con él."
                     : "El turno pasa automáticamente al siguiente en la lista.")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(Color.red)
                }
            }
        }
    }

    private var canSubmit: Bool {
        !selectedUserIds.isEmpty && !isSubmitting
    }

    // MARK: - Load + Save

    private func load() async {
        phase = .loading
        do {
            let event = try await app.eventRepo.event(eventId)
            guard let seriesId = event.seriesId else {
                phase = .empty
                return
            }
            // Pre-fill selection + pickers from existing rotation config
            // when present — the user is editing, not starting fresh.
            if let series = try await app.resourceSeriesRepo.fetchById(seriesId),
               let existing = Self.rotationConfig(from: series.metadata) {
                selectedUserIds = existing.participants.map { $0.uuidString.lowercased() }
                order = existing.order
                replacementPolicy = existing.replacementPolicy
            }
            phase = .loaded(Loaded(
                seriesId: seriesId,
                currentCycle: event.cycleNumber ?? 0
            ))
        } catch {
            phase = .failed(
                CoordinatorError.from(error, fallback: "No pudimos cargar la rotación"),
                previous: nil
            )
        }
    }

    private func submit() async {
        guard case .loaded(let loaded) = phase else { return }
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }

        let participants = selectedUserIds.compactMap { UUID(uuidString: $0) }
        guard !participants.isEmpty else {
            errorMessage = "Elige al menos un miembro."
            return
        }

        do {
            try await app.resourceSeriesRepo.setRotationConfig(
                seriesId: loaded.seriesId,
                participants: participants,
                order: order,
                replacementPolicy: replacementPolicy,
                purpose: "host",
                // Pass the CURRENT event's cycle as offset so the next
                // occurrence (cycle+1) resolves to participants[0]
                // post-mig 00336. Without this, the rotation cursor
                // would keep advancing from wherever it was before the
                // reorder — surprising users who reorder expecting
                // their first pick to host next.
                cycleOffset: loaded.currentCycle
            )
            onSaved()
            dismiss()
        } catch {
            errorMessage = CoordinatorError.from(
                error,
                fallback: "No pudimos guardar la rotación"
            ).title
        }
    }

    // MARK: - Wire shape decoder

    /// Pulls the rotation sub-config out of `resource_series.metadata`
    /// so the editor pre-fills with what's already saved. Mirrors the
    /// shape the cron + `RotationSectionView` read — one source of truth
    /// for the path, kept in sync by `setRotationConfig` writing the
    /// matching object back.
    private struct RotationConfig {
        let participants: [UUID]
        let order: String
        let replacementPolicy: String
    }

    private static func rotationConfig(from metadata: JSONConfig) -> RotationConfig? {
        guard case .object(let root) = metadata,
              case .object(let caps)? = root["capability_configs"],
              case .object(let rotation)? = caps["rotation"] else {
            return nil
        }
        var participants: [UUID] = []
        if case .array(let items)? = rotation["participants"] {
            for item in items {
                if case .string(let s) = item, let uid = UUID(uuidString: s) {
                    participants.append(uid)
                }
            }
        }
        return RotationConfig(
            participants: participants,
            order: rotation["order"]?.stringValue ?? "sequential",
            replacementPolicy: rotation["replacementPolicy"]?.stringValue ?? "skip_to_next"
        )
    }
}
