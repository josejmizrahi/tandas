import SwiftUI
import RuulCore

/// R.RES.POLICY.D.UI — sheet para que el owner edite el override de
/// `reservation_policy` per-recurso. El backend hace lookup composit:
/// override > subtype default. Si NO hay override, el recurso hereda el
/// default del subtype del catalog (R.RES.POLICY.A).
///
/// Founder Flow #5 rationale: Casa Valle hereda 'day' del subtype
/// primary_residence pero el owner puede setear min=2 días, advance=90, etc.
///
/// Edit fields: minDurationUnits, maxDurationUnits (opcional), advanceWindowDays
/// (opcional), requiresApproval. Granularity es read-only (propiedad del
/// subtype, no override-able — cambiar día↔hora requeriría reseteo del
/// recurso completo).
public struct EditReservationPolicyOverrideSheet: View {
    let resource: Resource
    let subtypeDefault: ReservationPolicy
    let container: DependencyContainer
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var runner = ActionRunner()

    /// Si nil, NO hay override actualmente; los valores del form muestran
    /// el default del subtype como placeholder visual y guardar crea override.
    @State private var hasOverride: Bool
    @State private var minDurationUnits: Int
    @State private var hasMaxDuration: Bool
    @State private var maxDurationUnits: Int
    @State private var hasAdvanceWindow: Bool
    @State private var advanceWindowDays: Int
    @State private var requiresApproval: Bool

    public init(
        resource: Resource,
        subtypeDefault: ReservationPolicy,
        currentOverride: ReservationPolicy?,
        container: DependencyContainer,
        onSaved: @escaping () -> Void
    ) {
        self.resource = resource
        self.subtypeDefault = subtypeDefault
        self.container = container
        self.onSaved = onSaved
        let effective = currentOverride ?? subtypeDefault
        _hasOverride = State(initialValue: currentOverride != nil)
        _minDurationUnits = State(initialValue: effective.minDurationUnits)
        _hasMaxDuration = State(initialValue: effective.maxDurationUnits != nil)
        _maxDurationUnits = State(initialValue: effective.maxDurationUnits ?? max(effective.minDurationUnits, 7))
        _hasAdvanceWindow = State(initialValue: effective.advanceWindowDays != nil)
        _advanceWindowDays = State(initialValue: effective.advanceWindowDays ?? 30)
        _requiresApproval = State(initialValue: effective.requiresApproval)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Unidad", value: subtypeDefault.granularity.label)
                } header: {
                    Text("Granularidad")
                } footer: {
                    Text("La unidad se define en el subtipo del recurso y no se puede cambiar aquí.")
                }

                Section {
                    Stepper(value: $minDurationUnits, in: 1...365) {
                        LabeledContent("Mínimo", value: durationLabel(minDurationUnits))
                    }
                    Toggle("Definir máximo", isOn: $hasMaxDuration)
                    if hasMaxDuration {
                        Stepper(value: $maxDurationUnits, in: minDurationUnits...365) {
                            LabeledContent("Máximo", value: durationLabel(maxDurationUnits))
                        }
                    }
                } header: {
                    Text("Duración permitida")
                }

                Section {
                    Toggle("Limitar adelanto", isOn: $hasAdvanceWindow)
                    if hasAdvanceWindow {
                        Stepper(value: $advanceWindowDays, in: 1...730) {
                            LabeledContent("Con hasta", value: "\(advanceWindowDays) día\(advanceWindowDays == 1 ? "" : "s")")
                        }
                    }
                } header: {
                    Text("Ventana de adelanto")
                } footer: {
                    Text("Los miembros podrán reservar hasta esa cantidad de días en el futuro.")
                }

                Section {
                    Toggle("Requiere aprobación", isOn: $requiresApproval)
                } footer: {
                    Text(requiresApproval
                         ? "Un admin del espacio debe aprobar cada reserva antes de confirmarse."
                         : "Las reservas se confirman automáticamente si no hay conflicto.")
                }

                if hasOverride {
                    Section {
                        Button(role: .destructive) {
                            Task { await clearOverride() }
                        } label: {
                            Label("Volver al default del subtipo", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(runner.isRunning)
                    } footer: {
                        Text("El recurso heredará la política default de \(subtypeDefault.granularity.label.lowercased()).")
                    }
                }
            }
            .navigationTitle("Política de reservación")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        Task { await save() }
                    }
                    .disabled(runner.isRunning)
                }
            }
            .actionErrorAlert(runner)
        }
        .ruulSheet()
    }

    private func durationLabel(_ units: Int) -> String {
        switch subtypeDefault.granularity {
        case .day:       return "\(units) día\(units == 1 ? "" : "s")"
        case .hour:      return "\(units) hora\(units == 1 ? "" : "s")"
        case .eventSlot: return "Un evento"
        case .none:      return "—"
        }
    }

    private func save() async {
        let policy = ReservationPolicy(
            granularity: subtypeDefault.granularity,
            minDurationUnits: minDurationUnits,
            maxDurationUnits: hasMaxDuration ? maxDurationUnits : nil,
            advanceWindowDays: hasAdvanceWindow ? advanceWindowDays : nil,
            requiresApproval: requiresApproval
        )
        let newMetadata = mergeMetadata(addingOverride: policy.toJSONValue())
        let success = await runner.run {
            _ = try await container.rpc.updateResource(UpdateResourceInput(
                resourceId: resource.id,
                metadata: newMetadata
            ))
        }
        if success {
            onSaved()
            dismiss()
        }
    }

    private func clearOverride() async {
        let newMetadata = mergeMetadata(removingOverride: true)
        let success = await runner.run {
            _ = try await container.rpc.updateResource(UpdateResourceInput(
                resourceId: resource.id,
                metadata: newMetadata
            ))
        }
        if success {
            onSaved()
            dismiss()
        }
    }

    /// Combina el metadata existente del resource con la modificación al
    /// `reservation_policy_override` key. Preserva los otros fields que el
    /// resource pueda tener en metadata (vehicle subtype fields, etc.).
    private func mergeMetadata(addingOverride newOverride: JSONValue? = nil, removingOverride: Bool = false) -> JSONValue {
        var dict: [String: JSONValue] = {
            if case .object(let existing) = resource.metadata { return existing }
            return [:]
        }()
        if removingOverride {
            dict.removeValue(forKey: "reservation_policy_override")
        } else if let newOverride {
            dict["reservation_policy_override"] = newOverride
        }
        return .object(dict)
    }
}
