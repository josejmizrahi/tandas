import SwiftUI
import RuulCore

/// V2-G4.2 — target proposes a payment plan for a monetary sanction.
/// Self-party only: backend rejects if the actor is not the target.
struct ProposePaymentPlanSheet: View {
    let container: DependencyContainer
    let sanction: GroupSanction
    let paymentStatus: SanctionPaymentStatus
    let onProposed: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var installments: Int = 4
    @State private var firstDueAt: Date = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var intervalDays: Int = 30
    @State private var notes: String = ""
    @State private var isSubmitting: Bool = false
    @State private var error: UserFacingError?

    private let installmentRange: ClosedRange<Int> = 2...12
    private let intervalOptions: [Int] = [7, 14, 30, 60]

    var body: some View {
        NavigationStack {
            Form {
                Section("Monto a programar") {
                    LabeledContent {
                        Text(formatAmount(paymentStatus.amountOutstanding))
                            .monospacedDigit()
                    } label: {
                        Text("Pendiente")
                    }
                }

                Section("Cuotas") {
                    Stepper(value: $installments, in: installmentRange) {
                        HStack {
                            Text("Cuotas")
                            Spacer()
                            Text("\(installments)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent {
                        Text(formatAmount(perInstallment))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } label: {
                        Text("Cada cuota")
                    }
                }

                Section("Calendario") {
                    DatePicker("Primera cuota", selection: $firstDueAt, in: Date()..., displayedComponents: .date)
                    Picker("Cada", selection: $intervalDays) {
                        ForEach(intervalOptions, id: \.self) { days in
                            Text(intervalLabel(days)).tag(days)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Notas (opcional)") {
                    TextField("Por qué eligiste este plan", text: $notes, axis: .vertical)
                        .lineLimit(1...4)
                }

                Section {
                    Text("Esto declara cómo planeas pagar. No retira dinero automáticamente — pagas cada cuota como un settlement normal.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Plan de pago")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting { ProgressView() } else { Text("Proponer") }
                    }
                    .disabled(isSubmitting)
                }
            }
            .alert(
                error?.title ?? "",
                isPresented: Binding(
                    get: { error != nil },
                    set: { if !$0 { error = nil } }
                ),
                actions: { Button("OK") { error = nil } },
                message: { Text(error?.message ?? "") }
            )
        }
    }

    private var perInstallment: Decimal {
        guard installments > 0 else { return 0 }
        return paymentStatus.amountOutstanding / Decimal(installments)
    }

    private func intervalLabel(_ days: Int) -> String {
        switch days {
        case 7:  return "1 sem"
        case 14: return "2 sem"
        case 30: return "1 mes"
        case 60: return "2 meses"
        default: return "\(days) d"
        }
    }

    private func formatAmount(_ value: Decimal) -> String {
        let n = NSDecimalNumber(decimal: value)
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        return f.string(from: n) ?? "\(value)"
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            _ = try await container.sanctionsRepository.proposePaymentPlan(
                sanctionId: sanction.id,
                installments: installments,
                firstDueAt: firstDueAt,
                intervalDays: intervalDays,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : notes.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            onProposed()
        } catch {
            self.error = UserFacingError.from(error)
        }
    }
}
