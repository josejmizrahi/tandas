import SwiftUI
import RuulCore
import RuulUI

/// Phase 4.4 (2026-05-26): "Cobrar cuota al grupo".
///
/// Founder ask: any member can mark one or more members as owing money
/// to the shared pool — for poker buy-ins, cuotas mensuales, tanda
/// contributions, viaje fund commitments, etc. The cuota is recorded
/// as an obligation right now; the actual cash arrives when each
/// debtor (or someone on their behalf) calls `pay_pool_charge`.
///
/// Backend RPC: `issue_pool_charges` (mig 20260526040000). Idempotente
/// via a stable `clientId` generated on sheet open — re-tapping after
/// an error reuses it so the server returns the original batch instead
/// of duplicating.
///
/// Form
/// ====
///   * **¿A quién?** — multi-select. Defaults to everyone except viewer
///     (the most common pattern: the host cobra a los demás), but the
///     viewer can include themselves with a single tap.
///   * **Monto por persona** — flat amount applied to every debtor.
///   * **Concepto** — required free-text label (poker, cuota mayo,
///     buy-in semanal).
///   * **Fecha límite (opcional)** — past-due cuotas surface
///     distinctively in the pending list. Off by default — most cuotas
///     don't have a hard deadline.
///   * **Contexto (opcional, pre-filled)** — when invoked from a
///     resource detail, the source resource is locked.
@MainActor
public struct IssuePoolChargeSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let groupId: UUID
    public let currency: String
    public let members: [MemberWithProfile]
    /// Optional resource scope (event/asset/space). When set, every
    /// obligation in the batch carries this as `source_resource_id`.
    public let sourceResource: (id: UUID, name: String)?
    public let onDidIssue: () -> Void

    @State private var selectedMemberIds: Set<UUID> = []
    @State private var amountText: String = ""
    @State private var reason: String = ""
    @State private var hasDueDate: Bool = false
    @State private var dueDate: Date = .now.addingTimeInterval(60 * 60 * 24 * 7)
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?
    @State private var clientId: UUID = UUID()
    @State private var successPhrase: String?

    public init(
        groupId: UUID,
        currency: String,
        members: [MemberWithProfile],
        sourceResource: (id: UUID, name: String)? = nil,
        onDidIssue: @escaping () -> Void
    ) {
        self.groupId = groupId
        self.currency = currency
        self.members = members
        self.sourceResource = sourceResource
        self.onDidIssue = onDidIssue
    }

    public var body: some View {
        NavigationStack {
            Form {
                debtorsSection
                amountSection
                reasonSection
                dueDateSection
                if let sourceResource {
                    Section {
                        Label("Para \(sourceResource.name)", systemImage: "tag")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    } footer: {
                        Text("La cuota queda atribuida a este recurso.")
                            .font(.caption)
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(Color.ruulNegative)
                    }
                }
                if let phrase = successPhrase {
                    Section {
                        Label(phrase, systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.ruulPositive)
                    }
                }
            }
            .animation(.snappy(duration: 0.22), value: successPhrase)
            .ruulSheetToolbar("Cobrar cuota al grupo")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmButtonLabel) {
                        RuulHaptic.light.trigger()
                        Task { await submit() }
                    }
                    .disabled(!canSubmit || isSubmitting || successPhrase != nil)
                }
            }
            .sensoryFeedback(.success, trigger: successPhrase)
            .onAppear {
                // Default selection: everyone except the viewer. The
                // host typically cobra a los demás; including yourself
                // is one extra tap if needed.
                if selectedMemberIds.isEmpty {
                    let me = members.first(where: { $0.member.userId == app.session?.user.id })?.member.id
                    selectedMemberIds = Set(members.map { $0.member.id }.filter { $0 != me })
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(.ultraThinMaterial)
    }

    // MARK: - Sections

    private var debtorsSection: some View {
        Section {
            ForEach(members, id: \.member.id) { row in
                debtorRow(row)
            }
            HStack {
                Button("Todos") { selectedMemberIds = Set(members.map { $0.member.id }) }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Ninguno") { selectedMemberIds.removeAll() }
                    .buttonStyle(.bordered)
                    .disabled(selectedMemberIds.isEmpty)
            }
            .font(.caption)
        } header: {
            HStack {
                Text("¿A quién le vas a cobrar?")
                Spacer()
                Text("\(selectedMemberIds.count) de \(members.count)")
                    .foregroundStyle(Color.secondary)
                    .monospacedDigit()
            }
        } footer: {
            Text("Cada persona seleccionada queda con una cuota pendiente por el mismo monto.")
                .font(.caption)
        }
    }

    private func debtorRow(_ row: MemberWithProfile) -> some View {
        Button {
            if selectedMemberIds.contains(row.member.id) {
                selectedMemberIds.remove(row.member.id)
            } else {
                selectedMemberIds.insert(row.member.id)
            }
        } label: {
            HStack(spacing: RuulSpacing.md) {
                Image(systemName: selectedMemberIds.contains(row.member.id)
                      ? "checkmark.circle.fill"
                      : "circle")
                    .foregroundStyle(selectedMemberIds.contains(row.member.id)
                                     ? Color.ruulAccent
                                     : Color(.tertiaryLabel))
                Text(row.displayName)
                    .foregroundStyle(Color.primary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var amountSection: some View {
        Section {
            HStack {
                Text("$")
                    .foregroundStyle(Color.secondary)
                TextField("0", text: $amountText)
                    .keyboardType(.decimalPad)
                    .monospacedDigit()
                Text(currency)
                    .foregroundStyle(Color.secondary)
            }
        } header: {
            Text("Monto por persona")
        } footer: {
            if let cents = parsedCents, selectedMemberIds.count > 1 {
                let total = cents * Int64(selectedMemberIds.count)
                Text("Total que entra al pool: \(formattedCents(total))")
                    .font(.caption)
            } else {
                Text("Mismo monto para cada deudor.")
                    .font(.caption)
            }
        }
    }

    private var reasonSection: some View {
        Section("Concepto") {
            TextField("ej: poker viernes, cuota mayo, buy-in", text: $reason, axis: .vertical)
                .lineLimit(1...2)
        }
    }

    private var dueDateSection: some View {
        Section {
            Toggle("Fecha límite", isOn: $hasDueDate)
            if hasDueDate {
                DatePicker(
                    "Vence el",
                    selection: $dueDate,
                    in: Date()...,
                    displayedComponents: [.date]
                )
            }
        } footer: {
            Text("Marca cuotas vencidas con un acento distinto en el listado.")
                .font(.caption)
        }
    }

    // MARK: - Submit

    private var canSubmit: Bool {
        guard !selectedMemberIds.isEmpty else { return false }
        guard let cents = parsedCents, cents > 0 else { return false }
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return true
    }

    private var parsedCents: Int64? {
        let normalized = amountText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty, let pesos = Double(normalized), pesos > 0 else {
            return nil
        }
        return Int64((pesos * 100).rounded())
    }

    private var confirmButtonLabel: String {
        if successPhrase != nil { return "Listo" }
        if isSubmitting { return "Registrando…" }
        return selectedMemberIds.count > 1 ? "Cobrar a \(selectedMemberIds.count)" : "Cobrar"
    }

    @MainActor
    private func submit() async {
        guard let cents = parsedCents else { return }
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let debtors = Array(selectedMemberIds)
        isSubmitting = true
        errorMessage = nil
        do {
            _ = try await app.ledgerRepo.issuePoolCharges(
                groupId: groupId,
                debtorMemberIds: debtors,
                amountCents: cents,
                currency: currency,
                reason: trimmedReason.isEmpty ? nil : trimmedReason,
                dueAt: hasDueDate ? dueDate : nil,
                sourceResourceId: sourceResource?.id,
                clientId: clientId
            )
            isSubmitting = false
            successPhrase = composeSuccess(amountCents: cents, count: debtors.count)
            try? await Task.sleep(for: .milliseconds(700))
            onDidIssue()
            dismiss()
        } catch {
            isSubmitting = false
            errorMessage = error.localizedDescription
            RuulHaptic.error.trigger()
        }
    }

    private func composeSuccess(amountCents: Int64, count: Int) -> String {
        let per = formattedCents(amountCents)
        if count == 1 {
            let name = members.first(where: { $0.member.id == selectedMemberIds.first })?.displayName
                ?? "este miembro"
            return "Cobraste \(per) a \(name)"
        }
        return "Cobraste \(per) a \(count) personas"
    }

    private func formattedCents(_ cents: Int64) -> String {
        let amount = Decimal(cents) / 100
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.locale = Locale(identifier: "es_MX")
        f.maximumFractionDigits = 0
        return f.string(from: amount as NSDecimalNumber) ?? "\(currency) \(cents / 100)"
    }
}
